use sysinfo::{System, Pid};
use tokio::time::{interval, Duration};

/// Start background task to collect system metrics (CPU, memory)
pub fn start_system_metrics_collector() {
    tokio::spawn(async {
        let mut sys = System::new_all();
        let pid = Pid::from_u32(std::process::id());
        let mut interval = interval(Duration::from_secs(5));
        
        loop {
            interval.tick().await;
            
            sys.refresh_all();
            
            // Process metrics
            if let Some(process) = sys.process(pid) {
                // Memory metrics (bytes)
                let memory_bytes = process.memory();
                metrics::gauge!("process_resident_memory_bytes")
                    .set(memory_bytes as f64);
                
                // CPU usage percentage
                let cpu_usage = process.cpu_usage() as f64;
                metrics::gauge!("process_cpu_usage_percent")
                    .set(cpu_usage);
            }
            
            // System-wide memory metrics (bytes)
            let total_memory = sys.total_memory();
            let used_memory = sys.used_memory();
            let available_memory = sys.available_memory();
            
            metrics::gauge!("node_memory_MemTotal_bytes")
                .set(total_memory as f64);
            metrics::gauge!("node_memory_MemUsed_bytes")
                .set(used_memory as f64);
            metrics::gauge!("node_memory_MemAvailable_bytes")
                .set(available_memory as f64);
        }
    });
}
