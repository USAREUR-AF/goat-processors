cmake_minimum_required(VERSION 3.16)
project(goat_correlator_cpp CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# correlate.md "Floats": no fused multiply-add, no extended precision.
# -ffp-contract=off stops a*b + c being contracted; on x86-64 doubles use SSE2,
# which keeps no extended-precision intermediates (-mfpmath=sse makes that explicit).
set(CORR_FLOAT_FLAGS -ffp-contract=off)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|i[3-6]86")
  list(APPEND CORR_FLOAT_FLAGS -msse2 -mfpmath=sse)
endif()

get_filename_component(CORR_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

add_library(correlator src/json.cpp src/pack.cpp src/engine.cpp src/assign.cpp)
target_include_directories(correlator PUBLIC src)
target_compile_options(correlator PRIVATE -Wall -Wextra ${CORR_FLOAT_FLAGS})

add_executable(run_vectors test/run_vectors.cpp)
target_link_libraries(run_vectors PRIVATE correlator)
target_compile_definitions(run_vectors PRIVATE CORR_REPO_ROOT="${CORR_REPO_ROOT}")
target_compile_options(run_vectors PRIVATE -Wall -Wextra ${CORR_FLOAT_FLAGS})

enable_testing()
add_test(NAME vectors COMMAND run_vectors "${CORR_REPO_ROOT}")
