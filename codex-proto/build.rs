fn main() {
    let protoc = protoc_bin_vendored::protoc_bin_path().expect("vendored protoc");
    std::env::set_var("PROTOC", protoc);

    let proto_root = std::path::PathBuf::from("../proto");
    let files = [
        proto_root.join("session.proto"),
        proto_root.join("thread.proto"),
        proto_root.join("run.proto"),
        proto_root.join("transport.proto"),
    ];

    prost_build::Config::new()
        .compile_protos(
            &files
                .iter()
                .map(|path| path.as_path())
                .collect::<Vec<_>>(),
            &[proto_root.as_path()],
        )
        .expect("compile protos");
}
