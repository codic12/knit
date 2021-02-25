extern crate libc;
use std::{
	self,
	mem,
	env,
	ptr,
	path::{
		Path
	},
	process::{
		self,
		Command
	},
};
mod config {
	pub const TIMEOUT: u32 = 30;
	pub const INITCMD: [&str; 1] = ["/bin/secinit.init"];
}

struct Signal {
	sig: libc::c_int,
	handler: unsafe fn(),
}

static SIGMAP: [Signal; 4] = [
    Signal { sig: libc::SIGUSR1, handler: sigpoweroff },
    Signal { sig: libc::SIGCHLD, handler: sigreap },
    Signal { sig: libc::SIGALRM, handler: sigreap },
    Signal { sig: libc::SIGINT, handler: sigreboot }
];

unsafe fn _main() {
	let mut set: libc::sigset_t = mem::zeroed();
	let mut sig: i32 = 0;
	if process::id() != 1 {
		panic!("Must be running as the first process (PID1).");
	}
	let root = Path::new("/");
	assert!(env::set_current_dir(&root).is_ok());
	libc::sigfillset(&mut set);
	libc::sigprocmask(libc::SIG_BLOCK, &set, ptr::null_mut());
	spawn(&config::INITCMD);
	loop {
		libc::alarm(config::TIMEOUT);
		libc::sigwait(&mut set, &mut sig);
		for s in &SIGMAP {
			if s.sig == sig { 
				(s.handler)();
				break;
			 }
		}
	}
}

fn main() {
	unsafe { _main(); }
}

fn sigpoweroff() {}
unsafe fn sigreap() {
	while libc::waitpid(-1, ptr::null_mut(), libc::WNOHANG) > 0 {}
	libc::alarm(config::TIMEOUT);
}
fn sigreboot() {}
fn spawn(cmd: &[&str]) {
	let exec = Command::new(cmd[0])
		.args(&cmd[1..])
		.status();
	match exec {
		Ok(s) => println!("Exit status of {}: {}", cmd[0], s),
		Err(e) => eprintln!("{}", e),
	}
}
