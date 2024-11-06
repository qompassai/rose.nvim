# Configuration
SHELL := /bin/bash
.DEFAULT_GOAL := help
.PHONY: test lint format help clean

# Directories
TEST_DIR := tests
PLUGIN_DIR := lua
BUILD_DIR := build

# Tools and flags
NVIM ?= nvim
LUACHECK ?= luacheck
STYLUA ?= stylua
CLANG_FORMAT ?= clang-format
CMAKE ?= cmake

# Test configuration
TEST_INIT := $(TEST_DIR)/minimal_init.lua

## Help target
help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

test: ## Run Plenary tests
	@$(NVIM) --headless -u $(TEST_INIT) -c "PlenaryBustedDirectory $(TEST_DIR) { minimal_init = '$(TEST_INIT)'}"

lint: ## Run luacheck
	@$(LUACHECK) $(PLUGIN_DIR)

format: ## Format Lua files
	@$(STYLUA) -v -f .stylua.toml $$(find . -type f -name '*.lua')

clean: ## Clean build artifacts
	@rm -rf $(BUILD_DIR)
	@echo "Cleaned build directory"

# CMake alternative
cmake-build: ## Build using CMake
	@mkdir -p $(BUILD_DIR)
	@cd $(BUILD_DIR) && $(CMAKE) .. \
		-DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
		-DCMAKE_C_COMPILER=clang \
		-DCMAKE_CXX_COMPILER=clang++
	@cd $(BUILD_DIR) && $(CMAKE) --build .

