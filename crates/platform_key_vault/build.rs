use std::{env, path::PathBuf, process::Command};

fn run(command: &mut Command, description: &str) {
    let status = command.status().unwrap_or_else(|error| {
        panic!("failed to start {description}: {error}");
    });
    assert!(status.success(), "{description} failed with {status}");
}

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("manifest directory"));
    let source = manifest.join("../../native/key_vault_abi");
    let build = PathBuf::from(env::var("OUT_DIR").expect("output directory")).join("native");
    let target = env::var("TARGET").expect("target triple");
    assert!(
        target.contains("apple-darwin") || target.contains("windows"),
        "platform key vault supports macOS and Windows desktop hosts"
    );

    run(
        Command::new("cmake")
            .arg("-S")
            .arg(&source)
            .arg("-B")
            .arg(&build)
            .arg("-DCMAKE_BUILD_TYPE=Release")
            .arg("-DBUILD_TESTING=OFF"),
        "platform key vault configuration",
    );
    run(
        Command::new("cmake")
            .arg("--build")
            .arg(&build)
            .arg("--config")
            .arg("Release")
            .arg("--target")
            .arg("plushpal_key_vault"),
        "platform key vault build",
    );

    let release = build.join("Release");
    println!("cargo:rustc-link-search=native={}", build.display());
    println!("cargo:rustc-link-search=native={}", release.display());
    println!("cargo:rustc-link-lib=static=plushpal_key_vault");
    if target.contains("apple-darwin") {
        println!("cargo:rustc-link-lib=framework=Security");
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
        println!("cargo:rustc-link-lib=c++");
    } else {
        println!("cargo:rustc-link-lib=Advapi32");
    }
    println!("cargo:rerun-if-changed={}", source.display());
}
