use std::cell::{RefCell, RefMut, BorrowMutError};
use std::process::{Child, Command};

trait SaferBorrowMut<T> {
    fn safer_borrow_mut(&self) -> Result<RefMut<T>, BorrowMutError>;
}

impl<T> SaferBorrowMut<T> for RefCell<T> {
    fn safer_borrow_mut(&self) -> Result<RefMut<T>, BorrowMutError> { // this is safe to #unwrap() because it error handles without panic-ing. it is debatable, though, whether it should actually panic.`
        match self.try_borrow_mut() {
            Ok(x) => return Ok(x), 
            Err(e) => {
                eprintln!("error mutably borrowing. definitely a bug, please report. it is:\n{}", e);
                Err(e)
            }
        }
    }
}

#[derive(Debug, PartialEq)]
pub enum ServiceKind {
    Blocking,
    Daemon,
}

#[derive(Debug)]
pub struct Service<'a> {
    // represents a service, loadable at runtime
    pub name: &'a str,
    pub cmds: &'a [&'a [&'a str]], // lifetime hell! this is &[&[&str]], no need to use vec here
    pub kind: ServiceKind,
    pub rproc: RefCell<Vec<Child>>, // now here, it needs to be appended to after creation. see https://doc.rust-lang.org/book/ch15-05-interior-mutability.html,
    pub running: RefCell<bool>,
}

impl<'a> Service<'a> {
    pub fn load(&self) -> Result<(), BorrowMutError> {
        // send a message over the IPC UDS...
        for x in self.cmds.iter() {
            match Command::new(x[0]).args(&x[1..]).spawn() {
                Ok(x) => self.rproc.safer_borrow_mut()?.push(x), 
                Err(e) => eprintln!(
                    "error starting some command in service {}, error is:\n{}",
                    self.name, e
                ),
            }
        }
        self.running.replace(true);
        Ok(())
    }
    pub fn unload(&self) -> Result<(), BorrowMutError> {
        for cmd in self.rproc.safer_borrow_mut()?.iter_mut() {
            cmd.kill().unwrap(); // error handling goes here!
        }
        self.rproc.take();
        self.running.replace(false);
        Ok(())
    }

    pub fn enable(&self, now: bool) -> Result<(), BorrowMutError> {
        if now {
            return self.load();
        }
        Ok(())
        // now do the permanent change
    }

    pub fn disable(&self, now: bool) -> Result<(), BorrowMutError> {
        if now {
            return self.unload();
        }
        Ok(())
        // now do the permanent change
    }
}
