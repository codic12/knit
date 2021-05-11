extern crate libc; // include libc, because key functionality depends on it 
use std::{
    cell::RefCell,
    env,
    fs::read_to_string,
    // everything from rust's std goes here
    mem,
    path::Path,
    process,
    ptr,
};
pub mod service;
mod config {
    // temporary module providing compile-time config
    pub const TIMEOUT: u32 = 30;
}

#[derive(Debug)]
struct Signal {
    // represents a module
    sig: libc::c_int,
    handler: unsafe fn(),
}

static SIGMAP: [Signal; 2] = [
    Signal {
        sig: libc::SIGCHLD,
        handler: sigreap,
    },
    Signal {
        sig: libc::SIGALRM,
        handler: sigreap,
    },
];

unsafe fn _main() {
    let mut set: libc::sigset_t = mem::zeroed();
    let mut sig: i32 = 0;
    if process::id() != 1 {
        panic!("Must be running as the first process (PID1).");
    }
    // /proc/cmdline
    // ERROR HANDLING
    let cmdline_unwrapped = read_to_string("/proc/cmdline").unwrap();
    let root = Path::new("/");
    assert!(env::set_current_dir(&root).is_ok());
    libc::sigfillset(&mut set);
    libc::sigprocmask(libc::SIG_BLOCK, &set, ptr::null_mut());
    let mnt_service = service::Service {
        name: "mount",
        kind: service::ServiceKind::Blocking,
        cmds: &[&["mount", "/dev/nvme0n1p6", "/"]],
        running: RefCell::new(vec![]),
    };
    mnt_service.load();
    let cmdline = cmdline_unwrapped
        .split_ascii_whitespace()
        .collect::<Vec<&str>>();
    for ln in &cmdline {
        println!("CMDLINE: {}", ln);
    }
    loop {
        libc::alarm(config::TIMEOUT);
        libc::sigwait(&mut set, &mut sig);
        for s in &SIGMAP {
            if s.sig == sig {
                // if it is a handled signal...
                (s.handler)();
                break;
            } // if it is not, we simply ignore it.
        }
    }
}

fn main() {
    unsafe {
        _main();
    }
}


unsafe fn sigreap() {
    while libc::waitpid(-1, ptr::null_mut(), libc::WNOHANG) > 0 {}
    libc::alarm(config::TIMEOUT);
}

