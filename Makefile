# /qompassai//Rose.nvim/Makefile
# -------------------------------------
# Copyright (C) 2025 Qompass AI, All rights reserved
SHELL := /bin/bash
.DEFAULT_GOAL := help
.PHONY: test lint format help clean

TEST_DIR := tests
PLUGIN_DIR := lua
BUILD_DIR := build

NVIM ?= nvim
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

test:
	@$(NVIM) --headless -u $(TEST_INIT) -c "PlenaryBustedDirectory $(TEST_DIR) { minimal_init = '$(TEST_INIT)'}"

lint:
	@$(LUACHECK) $(PLUGIN_DIR)

format:
	@$(STYLUA) -v -f .stylua.toml $$(find . -type f -name '*.lua')

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
