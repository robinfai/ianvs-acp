SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
APP_NAME := ACP Client
APP_BUNDLE := $(ROOT_DIR)/build/macos/Build/Products/Release/$(APP_NAME).app
INSTALL_DIR ?= /Applications
INSTALL_DIR_ABS := $(abspath $(INSTALL_DIR))
INSTALLED_APP := $(INSTALL_DIR_ABS)/$(APP_NAME).app

FLUTTER ?= flutter
DART ?= dart

.PHONY: \
	help bootstrap format format-check analyze test test-rust \
	test-release-scripts verify run run-macos build build-macos \
	verify-macos install install-macos package package-macos clean

help: ## 显示可用命令。
	@printf '%s\n' \
		'用法：make <target>' \
		'' \
		'开发：' \
		'  bootstrap            解析 Flutter/Dart 依赖' \
		'  format               格式化 Dart 源码和测试' \
		'  format-check         检查 Dart 格式，不修改文件' \
		'  analyze              运行 Flutter 静态分析' \
		'  test                 在隔离 HOME 中运行 Flutter 测试' \
		'  test-rust            验证 Rust workspace 和 Flutter/Rust 边界' \
		'  test-release-scripts 验证 macOS 发布脚本的安全约束' \
		'  verify               运行格式、分析、发布脚本、Rust 和 Flutter 测试' \
		'' \
		'macOS：' \
		'  run                  在 macOS 上运行应用' \
		'  build                构建本地 Release 应用' \
		'  verify-macos         验证已构建的本地应用包' \
		'  install              构建、验证并安装到 INSTALL_DIR' \
		'  package-macos        签名、公证并打包正式发布产物' \
		'' \
		'维护：' \
		'  clean                清理 Flutter 构建产物' \
		'' \
		'可覆盖参数：FLUTTER=<path> DART=<path> INSTALL_DIR=<directory>'

bootstrap: ## 解析 Flutter/Dart 依赖。
	cd "$(ROOT_DIR)" && $(FLUTTER) pub get

format: ## 格式化 Dart 源码和测试。
	cd "$(ROOT_DIR)" && $(DART) format lib test

format-check: ## 检查 Dart 格式，不修改文件。
	cd "$(ROOT_DIR)" && $(DART) format --output=none --set-exit-if-changed lib test

analyze: ## 运行 Flutter 静态分析。
	cd "$(ROOT_DIR)" && $(FLUTTER) analyze

test: ## 在隔离 HOME 中运行 Flutter 测试。
	"$(ROOT_DIR)/tool/flutter_test_isolated.sh"

test-rust: ## 验证 Rust workspace 和 Flutter/Rust 边界。
	"$(ROOT_DIR)/tool/verify_rust_runtime.sh"

test-release-scripts: ## 验证 macOS 发布脚本的安全约束。
	"$(ROOT_DIR)/tool/release_scripts_test.sh"

verify: ## 运行格式、分析、发布脚本、Rust 和 Flutter 测试，任一步失败即停止。
	@$(MAKE) --no-print-directory format-check
	@$(MAKE) --no-print-directory analyze
	@$(MAKE) --no-print-directory test-release-scripts
	@$(MAKE) --no-print-directory test-rust
	@$(MAKE) --no-print-directory test

run: run-macos

run-macos: ## 在 macOS 上运行应用。
	cd "$(ROOT_DIR)" && $(FLUTTER) run -d macos

build: build-macos

build-macos: ## 构建本地 Release 应用。
	cd "$(ROOT_DIR)" && $(FLUTTER) build macos --release

verify-macos: ## 验证已构建的本地应用包。
	@test -d "$(APP_BUNDLE)" || { printf '缺少应用包：%s\n' "$(APP_BUNDLE)" >&2; exit 1; }
	"$(ROOT_DIR)/tool/verify_macos_bundle.sh" "$(APP_BUNDLE)"

install: install-macos

install-macos: ## 构建、验证并原子安装应用，失败时恢复原应用。
	@test "$(INSTALL_DIR_ABS)" != '/' || { printf '%s\n' 'INSTALL_DIR 不能是根目录 /' >&2; exit 2; }
	@test -d "$(INSTALL_DIR_ABS)" || { printf '安装目录不存在：%s\n' "$(INSTALL_DIR_ABS)" >&2; exit 2; }
	@test -w "$(INSTALL_DIR_ABS)" || { printf '安装目录不可写：%s\n' "$(INSTALL_DIR_ABS)" >&2; exit 2; }
	@$(MAKE) --no-print-directory build-macos
	@$(MAKE) --no-print-directory verify-macos
	@set -euo pipefail; \
		install_dir="$$(cd "$(INSTALL_DIR_ABS)" && pwd -P)"; \
		bundle_dir="$$(cd "$$(dirname "$(APP_BUNDLE)")" && pwd -P)"; \
		installed_app="$$install_dir/$(APP_NAME).app"; \
		source_app="$$bundle_dir/$(APP_NAME).app"; \
		test "$$installed_app" != "$$source_app" || { \
			printf '%s\n' 'INSTALL_DIR 不能是构建产物所在目录' >&2; \
			exit 2; \
		}; \
		umask 077; \
		stage="$$(/usr/bin/mktemp -d "$$install_dir/.ianvs-acp-install.XXXXXX")"; \
		staged_app="$$stage/$(APP_NAME).app"; \
		previous_app="$$stage/previous.app"; \
		preserve_stage=0; \
		cleanup() { \
			if test "$$preserve_stage" -eq 0; then /bin/rm -rf -- "$$stage"; fi; \
		}; \
		trap cleanup EXIT; \
		trap 'exit 130' INT; \
		trap 'exit 143' TERM; \
		/usr/bin/ditto --rsrc --extattr "$$source_app" "$$staged_app"; \
		"$(ROOT_DIR)/tool/verify_macos_bundle.sh" "$$staged_app"; \
		if test -e "$$installed_app" || test -L "$$installed_app"; then \
			/bin/mv -- "$$installed_app" "$$previous_app"; \
		fi; \
		install_failed=0; \
		/bin/mv -- "$$staged_app" "$$installed_app" || install_failed=1; \
		if test "$$install_failed" -eq 0; then \
			"$(ROOT_DIR)/tool/verify_macos_bundle.sh" "$$installed_app" \
				|| install_failed=1; \
		fi; \
		if test "$$install_failed" -ne 0; then \
			rollback_failed=0; \
			/bin/rm -rf -- "$$installed_app" || rollback_failed=1; \
			if test -e "$$previous_app" || test -L "$$previous_app"; then \
				/bin/mv -- "$$previous_app" "$$installed_app" \
					|| rollback_failed=1; \
			fi; \
			if test "$$rollback_failed" -ne 0; then \
				preserve_stage=1; \
				printf '安装和自动恢复均失败；恢复材料保留在：%s\n' "$$stage" >&2; \
			else \
				printf '%s\n' '安装失败，已恢复原应用。' >&2; \
			fi; \
			exit 1; \
		fi; \
		printf '已安装：%s\n' "$$installed_app"

package: package-macos

package-macos: ## 签名、公证并打包正式发布产物；脚本会校验所需凭据。
	"$(ROOT_DIR)/tool/package_macos_release.sh"

clean: ## 清理 Flutter 构建产物。
	cd "$(ROOT_DIR)" && $(FLUTTER) clean
