pub mod session {
    include!(concat!(env!("OUT_DIR"), "/codexremote.v2.session.rs"));
}

pub mod thread {
    include!(concat!(env!("OUT_DIR"), "/codexremote.v2.thread.rs"));
}

pub mod run {
    include!(concat!(env!("OUT_DIR"), "/codexremote.v2.run.rs"));
}

pub mod transport {
    include!(concat!(env!("OUT_DIR"), "/codexremote.v2.transport.rs"));
}
