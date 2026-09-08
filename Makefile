# /qompassai//Rose.nvim/Makefile
# -------------------------------------
# Copyright (C) 2025 Qompass AI, All rights reserved
SHELL := /bin/bash
.DEFAULT_GOAL := help
.PHONY: test test-core test-tooling test-dap test-hub test-providers test-speech test-webui \
	test-live test-legacy lint format help clean

TEST_DIR := tests
PLUGIN_DIR := lua
BUILD_DIR := build

NVIM ?= nvim
PYTHON ?= python3
DIVER_ROOT ?=
LUACHECK ?= luacheck
STYLUA ?= stylua
CLANG_FORMAT ?= clang-format
CMAKE ?= cmake

TEST_INIT := $(TEST_DIR)/minimal_init.lua

help:
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

test: test-core test-tooling test-dap test-hub test-providers test-speech test-webui ## Run native offline tests without Neovim plugins

test-core: ## Native setup, HTTP, MCP, agent and validation tests
	@$(NVIM) --headless -u NONE -l $(TEST_DIR)/core.lua

test-tooling: ## Native tools; set DIVER_ROOT to test Diver completion too
	@DIVER_ROOT="$(DIVER_ROOT)" $(NVIM) --headless -u NONE -l $(TEST_DIR)/tooling.lua

test-dap: ## DAP protocol probes; ROSE_TEST_DEBUGPY=1 includes real debugpy
	@ROSE_TEST_PYTHON="$(PYTHON)" $(NVIM) --headless -u NONE -l $(TEST_DIR)/integration_dap.lua

test-hub: ## Offline Hub helper and native transfer lifecycle tests; no downloads
	@$(PYTHON) -m unittest discover -s $(TEST_DIR) -p test_hub.py -v
	@ROSE_TEST_PYTHON="$(PYTHON)" $(NVIM) --headless -u NONE -l $(TEST_DIR)/hub.lua

test-providers: ## Local HTTP fixtures for providers; no live API calls
	@ROSE_TEST_PYTHON="$(PYTHON)" $(NVIM) --headless -u NONE -l $(TEST_DIR)/providers.lua

test-speech: ## Offline speech fixtures (STT/TTS wire formats, fake recorder/player/piper); no microphone or live API
	@ROSE_TEST_PYTHON="$(PYTHON)" $(NVIM) --headless -u NONE -l $(TEST_DIR)/speech.lua

test-webui: ## Loopback web UI server: token, limits, routes with stubbed provider/Flow/speech
	@ROSE_TEST_PYTHON="$(PYTHON)" $(NVIM) --headless -u NONE -l $(TEST_DIR)/webui.lua

test-live: ## Optional installed basedpyright and Ruff; see tests/tooling_live.lua
	@DIVER_ROOT="$(DIVER_ROOT)" $(NVIM) --headless -u NONE -l $(TEST_DIR)/tooling_live.lua

test-legacy: ## Historical Plenary suite, not required or supported by native mode
	@$(NVIM) --headless -u $(TEST_INIT) -c "PlenaryBustedDirectory $(TEST_DIR) { minimal_init = '$(TEST_INIT)'}"

lint:
	@$(LUACHECK) $(PLUGIN_DIR)

format:
	@$(STYLUA) --config-path .stylua.toml lua/rose/native lua/rose/tooling lua/rose/providers \
		lua/rose/speech lua/rose/webui lua/rose/tools.lua lua/rose/debug.lua lua/rose/hub.lua

clean:
	@rm -rf $(BUILD_DIR)
	@echo "Cleaned build directory"

cmake-build:
	@mkdir -p $(BUILD_DIR)
	@cd $(BUILD_DIR) && $(CMAKE) .. \
		-DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
		-DCMAKE_C_COMPILER=clang \
		-DCMAKE_CXX_COMPILER=clang++
	@cd $(BUILD_DIR) && $(CMAKE) --build .
