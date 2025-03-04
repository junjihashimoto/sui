// Copyright (c) 2022, Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use futures::future::try_join_all;
use futures::future::BoxFuture;
use futures::FutureExt;
use futures::{stream::FuturesUnordered, StreamExt};
use prometheus::register_gauge_vec_with_registry;
use prometheus::register_histogram_vec_with_registry;
use prometheus::register_int_counter_vec_with_registry;
use prometheus::GaugeVec;
use prometheus::HistogramVec;
use prometheus::IntCounterVec;
use prometheus::Registry;
use sui_core::authority_aggregator::AuthorityAggregator;
use tokio::sync::OnceCell;

use crate::drivers::driver::Driver;
use crate::workloads::workload::Payload;
use crate::workloads::workload::WorkloadInfo;
use std::collections::{BTreeMap, VecDeque};
use std::sync::Arc;
use std::time::Duration;
use sui_core::authority_client::NetworkAuthorityClient;
use sui_core::quorum_driver::{QuorumDriverHandler, QuorumDriverMetrics};
use sui_types::crypto::EmptySignInfo;
use sui_types::messages::{
    ExecuteTransactionRequest, ExecuteTransactionRequestType, ExecuteTransactionResponse,
    TransactionEnvelope,
};
use tokio::sync::Barrier;
use tokio::time;
use tokio::time::Instant;
use tracing::{debug, error};
pub struct BenchMetrics {
    pub num_success: IntCounterVec,
    pub num_error: IntCounterVec,
    pub num_submitted: IntCounterVec,
    pub num_in_flight: GaugeVec,
    pub latency_s: HistogramVec,
}

const LATENCY_SEC_BUCKETS: &[f64] = &[
    0.01, 0.05, 0.1, 0.25, 0.5, 1., 2.5, 5., 10., 20., 30., 60., 90.,
];

impl BenchMetrics {
    fn new(registry: &Registry) -> Self {
        BenchMetrics {
            num_success: register_int_counter_vec_with_registry!(
                "num_success",
                "Total number of transaction success",
                &["workload"],
                registry,
            )
            .unwrap(),
            num_error: register_int_counter_vec_with_registry!(
                "num_error",
                "Total number of transaction errors",
                &["workload", "error_type"],
                registry,
            )
            .unwrap(),
            num_submitted: register_int_counter_vec_with_registry!(
                "num_submitted",
                "Total number of transaction submitted to sui",
                &["workload"],
                registry,
            )
            .unwrap(),
            num_in_flight: register_gauge_vec_with_registry!(
                "num_in_flight",
                "Total number of transaction in flight",
                &["workload"],
                registry,
            )
            .unwrap(),
            latency_s: register_histogram_vec_with_registry!(
                "latency_s",
                "Total time in seconds to return a response",
                &["workload"],
                LATENCY_SEC_BUCKETS.to_vec(),
                registry,
            )
            .unwrap(),
        }
    }
}

struct Stats {
    pub id: usize,
    pub num_success: u64,
    pub num_error: u64,
    pub num_no_gas: u64,
    pub num_submitted: u64,
    pub num_in_flight: u64,
    pub min_latency: Duration,
    pub max_latency: Duration,
    pub duration: Duration,
}

type RetryType = Box<(TransactionEnvelope<EmptySignInfo>, Box<dyn Payload>)>;
enum NextOp {
    Response(Option<(Duration, Box<dyn Payload>)>),
    Retry(RetryType),
}

async fn print_start_benchmark() {
    static ONCE: OnceCell<bool> = OnceCell::const_new();
    ONCE.get_or_init(|| async move {
        eprintln!("Starting benchmark!");
        true
    })
    .await;
}

pub struct BenchWorker {
    pub num_requests: u64,
    pub target_qps: u64,
    pub payload: Vec<Box<dyn Payload>>,
}

pub struct BenchDriver {
    pub stat_collection_interval: u64,
}

impl BenchDriver {
    pub fn new(stat_collection_interval: u64) -> BenchDriver {
        BenchDriver {
            stat_collection_interval,
        }
    }
    pub async fn make_workers(
        &self,
        workload_info: &WorkloadInfo,
        aggregator: &AuthorityAggregator<NetworkAuthorityClient>,
    ) -> Vec<BenchWorker> {
        let mut num_requests = workload_info.max_in_flight_ops / workload_info.num_workers;
        let mut target_qps = workload_info.target_qps / workload_info.num_workers;
        let mut workers = vec![];
        for i in 0..workload_info.num_workers {
            if i == workload_info.num_workers - 1 {
                num_requests += workload_info.max_in_flight_ops % workload_info.num_workers;
                target_qps += workload_info.target_qps % workload_info.num_workers;
            }
            if num_requests > 0 && target_qps > 0 {
                workers.push(BenchWorker {
                    num_requests,
                    target_qps,
                    payload: workload_info
                        .workload
                        .make_test_payloads(num_requests, aggregator)
                        .await,
                });
            }
        }
        workers
    }
}

#[async_trait]
impl Driver<()> for BenchDriver {
    async fn run(
        &self,
        workloads: Vec<WorkloadInfo>,
        aggregator: AuthorityAggregator<NetworkAuthorityClient>,
        registry: &Registry,
    ) -> Result<(), anyhow::Error> {
        let mut tasks = Vec::new();
        let (tx, mut rx) = tokio::sync::mpsc::channel(100);
        let mut bench_workers = vec![];
        for workload in workloads.iter() {
            bench_workers.extend(self.make_workers(workload, &aggregator).await);
        }
        let num_workers = bench_workers.len() as u64;
        if num_workers == 0 {
            return Err(anyhow!("No workers to run benchmark!"));
        }
        let stat_delay_micros = 1_000_000 * self.stat_collection_interval;
        let metrics = Arc::new(BenchMetrics::new(registry));
        let barrier = Arc::new(Barrier::new(num_workers as usize));
        for (i, worker) in bench_workers.into_iter().enumerate() {
            let request_delay_micros = 1_000_000 / worker.target_qps;
            let mut free_pool = worker.payload;
            let tx_cloned = tx.clone();
            let cloned_barrier = barrier.clone();
            let metrics_cloned = metrics.clone();
            // Make a per worker quorum driver, otherwise they all share the same task.
            let quorum_driver_handler =
                QuorumDriverHandler::new(aggregator.clone(), QuorumDriverMetrics::new_for_tests());
            let qd = quorum_driver_handler.clone_quorum_driver();
            let runner = tokio::spawn(async move {
                cloned_barrier.wait().await;
                print_start_benchmark().await;
                let mut num_success = 0;
                let mut num_error = 0;
                let mut min_latency = Duration::MAX;
                let mut max_latency = Duration::ZERO;
                let mut num_no_gas = 0;
                let mut num_in_flight: u64 = 0;
                let mut num_submitted = 0;
                let mut request_interval =
                    time::interval(Duration::from_micros(request_delay_micros));
                request_interval.set_missed_tick_behavior(time::MissedTickBehavior::Delay);
                let mut stat_interval = time::interval(Duration::from_micros(stat_delay_micros));
                let mut futures: FuturesUnordered<BoxFuture<NextOp>> = FuturesUnordered::new();

                let mut retry_queue: VecDeque<RetryType> = VecDeque::new();

                loop {
                    tokio::select! {
                            _ = stat_interval.tick() => {
                                if tx_cloned
                                    .try_send(Stats {
                                        id: i as usize,
                                        num_success,
                                        num_error,
                                        min_latency,
                                        max_latency,
                                        num_no_gas,
                                        num_in_flight,
                                        num_submitted,
                                        duration: Duration::from_micros(stat_delay_micros),
                                    })
                                    .is_err()
                                {
                                    debug!("Failed to update stat!");
                                }
                                num_success = 0;
                                num_error = 0;
                                num_no_gas = 0;
                                num_submitted = 0;
                                min_latency = Duration::MAX;
                                max_latency = Duration::ZERO;
                        }
                        _ = request_interval.tick() => {

                            // If a retry is available send that
                            // (sending retries here subjects them to our rate limit)
                            if let Some(b) = retry_queue.pop_front() {
                                num_error += 1;
                                num_submitted += 1;
                                metrics_cloned.num_submitted.with_label_values(&[&b.1.get_workload_type().to_string()]).inc();
                                let metrics_cloned = metrics_cloned.clone();
                                let start = Instant::now();
                                let res = qd
                                    .execute_transaction(ExecuteTransactionRequest {
                                        transaction: b.0.clone(),
                                        request_type: ExecuteTransactionRequestType::WaitForEffectsCert,
                                    })
                                    .map(move |res| {
                                        match res {
                                            Ok(ExecuteTransactionResponse::EffectsCert(result)) => {
                                                let (_, effects) = *result;
                                                let new_version = effects.effects.mutated.iter().find(|(object_ref, _)| {
                                                    object_ref.0 == b.1.get_object_id()
                                                }).map(|x| x.0).unwrap();
                                                let latency = start.elapsed();
                                                metrics_cloned.latency_s.with_label_values(&[&b.1.get_workload_type().to_string()]).observe(latency.as_secs_f64());
                                                metrics_cloned.num_success.with_label_values(&[&b.1.get_workload_type().to_string()]).inc();
                                                metrics_cloned.num_in_flight.with_label_values(&[&b.1.get_workload_type().to_string()]).dec();
                                                NextOp::Response(Some((
                                                    latency,
                                                    b.1.make_new_payload(new_version, effects.effects.gas_object.0),
                                                ),
                                                ))
                                            }
                                            Ok(resp) => {
                                                error!("unexpected_response: {:?}", resp);
                                                metrics_cloned.num_error.with_label_values(&[&b.1.get_workload_type().to_string(), "unknown_error"]).inc();
                                                NextOp::Retry(b)
                                            }
                                            Err(sui_err) => {
                                                error!("{}", sui_err);
                                                metrics_cloned.num_error.with_label_values(&[&b.1.get_workload_type().to_string(), &sui_err.to_string()]).inc();
                                                NextOp::Retry(b)
                                            }
                                        }
                                    });
                                futures.push(Box::pin(res));
                                continue
                            }

                            // Otherwise send a fresh request
                            if free_pool.is_empty() {
                                num_no_gas += 1;
                            } else {
                                let payload = free_pool.pop().unwrap();
                                num_in_flight += 1;
                                num_submitted += 1;
                                metrics_cloned.num_in_flight.with_label_values(&[&payload.get_workload_type().to_string()]).inc();
                                metrics_cloned.num_submitted.with_label_values(&[&payload.get_workload_type().to_string()]).inc();
                                let tx = payload.make_transaction();
                                let start = Instant::now();
                                let metrics_cloned = metrics_cloned.clone();
                                let res = qd
                                    .execute_transaction(ExecuteTransactionRequest {
                                        transaction: tx.clone(),
                                    request_type: ExecuteTransactionRequestType::WaitForEffectsCert,
                                })
                                .map(move |res| {
                                    match res {
                                        Ok(ExecuteTransactionResponse::EffectsCert(result)) => {
                                            let (_, effects) = *result;
                                            let new_version = effects.effects.mutated.iter().find(|(object_ref, _)| {
                                                object_ref.0 == payload.get_object_id()
                                            }).map(|x| x.0).unwrap();
                                            let latency = start.elapsed();
                                            metrics_cloned.latency_s.with_label_values(&[&payload.get_workload_type().to_string()]).observe(latency.as_secs_f64());
                                            metrics_cloned.num_success.with_label_values(&[&payload.get_workload_type().to_string()]).inc();
                                            metrics_cloned.num_in_flight.with_label_values(&[&payload.get_workload_type().to_string()]).dec();
                                            NextOp::Response(Some((
                                                latency,
                                                payload.make_new_payload(new_version, effects.effects.gas_object.0),
                                            )))
                                        }
                                        Ok(resp) => {
                                            error!("unexpected_response: {:?}", resp);
                                            metrics_cloned.num_error.with_label_values(&[&payload.get_workload_type().to_string(), "unknown_error"]).inc();
                                            NextOp::Retry(Box::new((tx, payload)))
                                        }
                                        Err(sui_err) => {
                                            error!("Retry due to error: {}", sui_err);
                                            metrics_cloned.num_error.with_label_values(&[&payload.get_workload_type().to_string(), &sui_err.to_string()]).inc();
                                            NextOp::Retry(Box::new((tx, payload)))
                                        }
                                    }
                                });
                                futures.push(Box::pin(res));
                            }
                        }
                        Some(op) = futures.next() => {
                            match op {
                                NextOp::Retry(b) => {
                                    retry_queue.push_back(b);
                                }
                                NextOp::Response(Some((latency, new_payload))) => {
                                    num_success += 1;
                                    num_in_flight -= 1;
                                    free_pool.push(new_payload);
                                    if latency > max_latency {
                                        max_latency = latency;
                                    }
                                    if latency < min_latency {
                                        min_latency = latency;
                                    }
                                }
                                NextOp::Response(None) => {
                                    // num_in_flight -= 1;
                                    unreachable!();
                                }
                            }
                        }
                    }
                }
            });
            tasks.push(runner);
        }

        tasks.push(tokio::spawn(async move {
            let mut stat_collection: BTreeMap<usize, Stats> = BTreeMap::new();
            let mut counter = 0;
            while let Some(s @ Stats {
                id,
                num_success: _,
                num_error: _,
                min_latency: _,
                max_latency: _,
                num_no_gas: _,
                num_in_flight: _,
                num_submitted: _,
                duration
            }) = rx.recv().await {
                stat_collection.insert(id, s);
                let mut total_qps: f32 = 0.0;
                let mut num_success: u64 = 0;
                let mut num_error: u64 = 0;
                let mut min_latency: Duration = Duration::MAX;
                let mut max_latency: Duration = Duration::ZERO;
                let mut num_in_flight: u64 = 0;
                let mut num_submitted: u64 = 0;
                let mut num_no_gas = 0;
                for (_, v) in stat_collection.iter() {
                    total_qps += v.num_success as f32 / duration.as_secs() as f32;
                    num_success += v.num_success;
                    num_error += v.num_error;
                    num_no_gas += v.num_no_gas;
                    num_submitted += v.num_submitted;
                    num_in_flight += v.num_in_flight;
                    min_latency = if v.min_latency < min_latency {
                        v.min_latency
                    } else {
                        min_latency
                    };
                    max_latency = if v.max_latency > max_latency {
                        v.max_latency
                    } else {
                        max_latency
                    };
                }
                let denom = num_success + num_error;
                let _error_rate = if denom > 0 {
                    num_error as f32 / denom as f32
                } else {
                    0.0
                };
                counter += 1;
                if counter % num_workers == 0 {
                    eprintln!("Throughput = {}, min_latency_ms = {}, max_latency_ms = {}, num_success = {}, num_error = {}, no_gas = {}, submitted = {}, in_flight = {}", total_qps, min_latency.as_millis(), max_latency.as_millis(), num_success, num_error, num_no_gas, num_submitted, num_in_flight);
                }
            }
        }));
        let _res: Vec<_> = try_join_all(tasks).await.unwrap().into_iter().collect();
        Ok(())
    }
}
