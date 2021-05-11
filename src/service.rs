use std::cell::RefCell;
use std::process::{Child, Command};

#[derive(Debug, PartialEq)]
pub enum ServiceKind {
    Blocking,
    Daemon,
}

#[derive(Debug)]
pub struct Service<'a> {
    // represents a service, loadable at runtime
    pub name: &'a str,
    pub cmds: &'a [&'a [&'a str]], // lifetime hell! this is 0&[&[&str]], no need to use vec here
    pub kind: ServiceKind,
    pub running: RefCell<Vec<Child>>, // now here, it needs to be appended to after creation. see https://doc.rust-lang.org/book/ch15-05-interior-mutability.html
}

impl<'a> Service<'a> {
    pub fn load(&self) {
        // send a message over the IPC UDS...
        for x in self.cmds.iter() {
            match Command::new(x[0]).args(&x[1..]).spawn() {
                Ok(x) => self.running.borrow_mut().push(x), // note: we use borrow_mut which can panic at runtime if it is borrowed multiple times. we could use try_borrow_mut, but it shouldn't panic since it exits scope.
                Err(e) => eprintln!(
                    "error starting some command in service {}, error is:\n{}",
                    self.name, e
                ),
            }
        }
    }
    pub fn unload(&self) {
        if self.kind == ServiceKind::Blocking {
            return;
        } // refuse outright
        for cmd in self.running.borrow_mut().iter_mut() {
            cmd.kill().unwrap(); // error handling goes here!
        }
        self.running.take();
    }

    pub fn enable(&self, now: bool) {
        if now {
            self.load()
        }
        // now do the permanent change
    }

    pub fn disable(&self, now: bool) {
        if now {
            self.unload()
        }
        // now do the permanent change
    }
}
