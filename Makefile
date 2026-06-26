PUBLIC_ROOT ?= $(HOME)/Downloads/PlushPal
ARTIFACTS_DIR ?= $(PUBLIC_ROOT)/artifacts
BUILD_DIR ?= $(PUBLIC_ROOT)/build

.PHONY: doctor format lint test native flutter desktop android-rust android-apk ios-simulator ios-device package-macos build-all build-product public-artifacts release-bundle publish-release public-clean public-repo-check test-product-layout verify-release-local check setup-chatterbox-voice setup-luxtts-voice run-demo run-mac-demo run-mac-luxtts

doctor:
	sh tools/product/doctor.sh

format:
	cargo fmt --all -- --check

lint:
	cargo clippy --workspace --all-targets -- -D warnings

test:
	cargo test --workspace
	cargo check -p plushpal-desktop-host --example model_smoke --features native-runtime
	cargo check -p plushpal-desktop-host --example voice_smoke --features native-runtime
	cargo check -p plushpal-desktop-host --example chatterbox_voice_smoke --features native-runtime

native:
	cmake -S native/llama_abi -B build/native-llama -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
	cmake --build build/native-llama --config Release -j 4
	ctest --test-dir build/native-llama --output-on-failure
	cmake -S native/key_vault_abi -B build/native-key-vault -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
	cmake --build build/native-key-vault --config Release -j 4
	ctest --test-dir build/native-key-vault --output-on-failure

flutter:
	cd apps/android/flutter_app && flutter analyze && flutter test && flutter build web --release --pwa-strategy=none --no-web-resources-cdn

desktop: flutter
	rsync -a --delete apps/android/flutter_app/build/web/ apps/station/macstation_host/assets/flutter_web/
	cargo build --release -p plushpal-desktop-host --features native-runtime

package-macos:
	PLUSHPAL_ARTIFACTS_DIR="$(ARTIFACTS_DIR)" \
	PLUSHPAL_BUILD_DIR="$(BUILD_DIR)" \
	CARGO_TARGET_DIR="$(BUILD_DIR)/cargo-target" \
	sh packaging/macos/package.sh

android-apk: android-rust
	cd apps/android/flutter_app && flutter build apk --debug

ios-simulator:
	cd apps/android/flutter_app && flutter build ios --simulator --debug

ios-device:
	cd apps/android/flutter_app && flutter build ios --release --no-codesign

build-all: package-macos android-apk ios-simulator ios-device

build-product: build-all

public-artifacts:
	sh packaging/build-public-artifacts.sh

release-bundle:
	sh packaging/create-release-bundle.sh

publish-release:
	@if [ -z "$(TAG)" ]; then echo "Usage: make publish-release TAG=v0.1.0 RELEASE_DIR=$(PUBLIC_ROOT)/release/v0.1.0"; exit 2; fi
	@if [ -z "$(RELEASE_DIR)" ]; then echo "Usage: make publish-release TAG=$(TAG) RELEASE_DIR=$(PUBLIC_ROOT)/release/$(TAG)"; exit 2; fi
	tools/github/create_release.py palwe-prafulla plushpal "$(TAG)" "$(RELEASE_DIR)"

public-clean:
	rm -rf "$(PUBLIC_ROOT)"

public-repo-check:
	sh tools/product/public_repo_check.sh

test-product-layout:
	sh packaging/macos/tests/check_product_layout.sh

setup-chatterbox-voice:
	sh tools/voice/setup_chatterbox_macos.sh

setup-luxtts-voice:
	sh tools/voice/setup_luxtts_macos.sh

run-demo:
	PLUSHPAL_RUNTIME_MODE=demo \
	cargo run --release -p plushpal-desktop-host --features native-runtime

run-mac-demo:
	PLUSHPAL_RUNTIME_MODE=demo \
	cargo run --release -p plushpal-desktop-host --features native-runtime

run-mac-luxtts:
	PLUSHPAL_VOICE_ENGINE=luxtts \
	PLUSHPAL_LUXTTS_PYTHON="$$(pwd)/.venv-luxtts/bin/python" \
	PLUSHPAL_LUXTTS_SCRIPT="$$(pwd)/tools/voice/luxtts_tts.py" \
	PLUSHPAL_LUXTTS_NUM_STEPS=8 \
	PLUSHPAL_LUXTTS_SPEED=0.88 \
	PLUSHPAL_LUXTTS_SEED=11 \
	PLUSHPAL_LUXTTS_REF_DURATION=180 \
	cargo run --release -p plushpal-desktop-host --features native-runtime

verify-release-local:
	sh packaging/verify-release-local.sh

android-rust:
	sh packaging/android/build-rust.sh

check: public-repo-check format lint test native flutter test-product-layout
