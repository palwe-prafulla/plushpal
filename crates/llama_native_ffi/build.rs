use std::{env, path::PathBuf, process::Command};

fn run(command: &mut Command, description: &str) {
    let status = command.status().unwrap_or_else(|error| {
        panic!("failed to start {description}: {error}");
    });
    assert!(status.success(), "{description} failed with {status}");
}

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("manifest directory"));
    let root = manifest.join("../..");
    let source = root.join("native/llama_abi");
    let build = PathBuf::from(env::var("OUT_DIR").expect("output directory")).join("native");
    let target = env::var("TARGET").expect("target triple");
    let mobile = target.contains("apple-ios") || target.contains("android");
    let llama_cpp = env::var_os("PLUSHPAL_LLAMA_CPP_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join("third_party/llama.cpp"));

    let mut configure = Command::new("cmake");
    configure
        .arg("-S")
        .arg(&source)
        .arg("-B")
        .arg(&build)
        .arg("-DCMAKE_BUILD_TYPE=Release")
        .arg("-DBUILD_TESTING=OFF")
        .arg(format!("-DPLUSHPAL_LLAMA_CPP_DIR={}", llama_cpp.display()))
        .arg(format!(
            "-DPLUSHPAL_LLAMA_SHARED={}",
            if mobile { "OFF" } else { "ON" }
        ));
    if mobile {
        configure.arg("-DGGML_NATIVE=OFF");
    }
    if target.contains("apple-ios") {
        configure
            .arg("-DCMAKE_SYSTEM_NAME=iOS")
            .arg("-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0")
            .arg(if target.starts_with("aarch64") {
                "-DCMAKE_OSX_ARCHITECTURES=arm64"
            } else {
                "-DCMAKE_OSX_ARCHITECTURES=x86_64"
            });
    } else if target.contains("android") {
        let ndk = env::var("ANDROID_NDK_HOME")
            .or_else(|_| env::var("ANDROID_NDK_ROOT"))
            .expect("ANDROID_NDK_HOME is required for Android native builds");
        let abi = if target.starts_with("aarch64") {
            "arm64-v8a"
        } else if target.starts_with("x86_64") {
            "x86_64"
        } else {
            panic!("unsupported Android Rust target: {target}");
        };
        configure
            .arg(format!(
                "-DCMAKE_TOOLCHAIN_FILE={ndk}/build/cmake/android.toolchain.cmake"
            ))
            .arg(format!("-DANDROID_ABI={abi}"))
            .arg("-DANDROID_PLATFORM=android-29");
    }
    run(&mut configure, "native llama configuration");
    run(
        Command::new("cmake")
            .arg("--build")
            .arg(&build)
            .arg("--config")
            .arg("Release")
            .arg("--target")
            .arg("plushpal_llama")
            .arg("-j")
            .arg("4"),
        "native llama build",
    );

    println!("cargo:rustc-link-search=native={}", build.display());
    println!(
        "cargo:rustc-link-lib={}plushpal_llama",
        if mobile { "static=" } else { "dylib=" }
    );
    if target.contains("apple-darwin") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", build.display());
    }
    if mobile {
        for directory in [
            build.join("llama.cpp/src"),
            build.join("llama.cpp/ggml/src"),
            build.join("llama.cpp/ggml/src/ggml-cpu"),
            build.join("llama.cpp/ggml/src/ggml-metal"),
        ] {
            println!("cargo:rustc-link-search=native={}", directory.display());
        }
        println!("cargo:rustc-link-lib=static=llama");
        println!("cargo:rustc-link-lib=static=ggml");
        println!("cargo:rustc-link-lib=static=ggml-base");
        println!("cargo:rustc-link-lib=static=ggml-cpu");
        if target.contains("apple-ios") {
            println!("cargo:rustc-link-lib=static=ggml-metal");
            for framework in ["Accelerate", "Foundation", "Metal", "MetalKit"] {
                println!("cargo:rustc-link-lib=framework={framework}");
            }
        }
        println!("cargo:rustc-link-lib=c++");
    }
    println!("cargo:rerun-if-changed={}", source.display());
    println!("cargo:rerun-if-env-changed=ANDROID_NDK_HOME");
    println!("cargo:rerun-if-env-changed=ANDROID_NDK_ROOT");
    println!("cargo:rerun-if-env-changed=PLUSHPAL_LLAMA_CPP_DIR");
    println!("cargo:rerun-if-changed={}", llama_cpp.display());
}
