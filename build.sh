# With Make
make format CLANG_FORMAT=clang-format-15

# With CMake
cmake -B build -DUSE_CLANG=ON -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++

