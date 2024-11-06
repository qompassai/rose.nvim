cmake_minimum_required(VERSION 3.20)
project(neovim_plugin LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Options
option(USE_CLANG "Build with Clang" ON)
option(ENABLE_TESTING "Enable testing" ON)

find_package(Lua REQUIRED)

add_custom_target(format
    COMMAND ${CMAKE_COMMAND} -E echo "Formatting code..."
    COMMAND stylua -v -f ${CMAKE_SOURCE_DIR}/.stylua.toml
            ${CMAKE_SOURCE_DIR}/lua
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

add_custom_target(lint
    COMMAND ${CMAKE_COMMAND} -E echo "Linting code..."
    COMMAND luacheck ${CMAKE_SOURCE_DIR}/lua
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

add_custom_target(nvim_test
    COMMAND nvim --headless
            -u ${CMAKE_SOURCE_DIR}/tests/minimal_init.lua
            -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua'}"
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

