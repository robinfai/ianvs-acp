use std::path::PathBuf;

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
    let mut args = std::env::args_os().skip(1);
    while let Some(argument) = args.next() {
        match argument.to_str() {
            Some("--database") => database = args.next().map(PathBuf::from),
            Some("--socket") => socket = args.next().map(PathBuf::from),
            Some("--allow-shutdown") => allow_shutdown = true,
            Some("--help" | "-h") => {
                println!("usage: ianvs-acpd --database PATH --socket PATH [--allow-shutdown]");
                return Ok(());
            }
            _ => return Err("unknown or invalid ianvs-acpd argument".into()),
        }
    }
    let database = database.ok_or("--database is required")?;
    let socket = socket.ok_or("--socket is required")?;
    DaemonHost::bind(database, socket, allow_shutdown)?.serve()?;
    Ok(())
}
