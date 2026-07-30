use std::path::PathBuf;

use ianvs_acp_core::SqliteStoragePolicy;
use ianvs_acpd::DaemonHost;

fn main() {
    if let Err(error) = run() {
        eprintln!("ianvs-acpd: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut database = None;
    let mut socket = None;
    let mut allow_shutdown = false;
    let mut max_database_bytes = None;
    let mut retention_days = None;
    let mut args = std::env::args_os().skip(1);
    while let Some(argument) = args.next() {
        match argument.to_str() {
            Some("--database") => database = args.next().map(PathBuf::from),
            Some("--socket") => socket = args.next().map(PathBuf::from),
            Some("--allow-shutdown") => allow_shutdown = true,
            Some("--max-database-bytes") => {
                let value = args.next().ok_or("--max-database-bytes requires a value")?;
                max_database_bytes = Some(
                    value
                        .to_str()
                        .ok_or("--max-database-bytes must be UTF-8")?
                        .parse::<u64>()
                        .map_err(|_| "--max-database-bytes must be an integer")?,
                );
            }
            Some("--retention-days") => {
                let value = args.next().ok_or("--retention-days requires a value")?;
                retention_days = Some(
                    value
                        .to_str()
                        .ok_or("--retention-days must be UTF-8")?
                        .parse::<u32>()
                        .map_err(|_| "--retention-days must be an integer")?,
                );
            }
            Some("--help" | "-h") => {
                println!(
                    "usage: ianvs-acpd --database PATH --socket PATH \
                     [--max-database-bytes BYTES] [--retention-days DAYS] \
                     [--allow-shutdown]"
                );
                return Ok(());
            }
            _ => return Err("unknown or invalid ianvs-acpd argument".into()),
        }
    }
    let database = database.ok_or("--database is required")?;
    let socket = socket.ok_or("--socket is required")?;
    let defaults = SqliteStoragePolicy::default();
    let storage_policy = SqliteStoragePolicy::new(
        max_database_bytes.unwrap_or(defaults.max_bytes()),
        retention_days.unwrap_or(defaults.retention_days()),
    )?;
    DaemonHost::bind_with_storage_policy(database, socket, allow_shutdown, storage_policy)?
        .serve()?;
    Ok(())
}
