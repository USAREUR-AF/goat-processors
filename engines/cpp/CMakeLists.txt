cmake_minimum_required(VERSION 3.16)
project(goat_processors_cpp CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# "Floats" of every spec: no fused multiply-add, no extended precision.
# -ffp-contract=off stops a*b + c being contracted; on x86-64 doubles use SSE2,
# which keeps no extended-precision intermediates (-mfpmath=sse makes that explicit).
set(GOAT_FLOAT_FLAGS -ffp-contract=off)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|i[3-6]86")
  list(APPEND GOAT_FLOAT_FLAGS -msse2 -mfpmath=sse)
endif()

# GOAT_COVERAGE=ON builds everything with gcc's own line coverage (--coverage,
# read with gcov); see README.md "Tests and coverage".
option(GOAT_COVERAGE "Build with gcc line coverage" OFF)
if(GOAT_COVERAGE)
  add_compile_options(--coverage -O0)
  add_link_options(--coverage)
endif()

get_filename_component(GOAT_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# The engine: one library, one directory per module (README.md "Layout").
add_library(goat_engine
  src/model/json.cpp src/model/report.cpp src/model/frame.cpp src/model/estimate.cpp src/model/pack_text.cpp
  src/snapshot/snapshot.cpp
  src/filter/pack.cpp src/filter/geometry.cpp src/filter/conditions.cpp src/filter/engine.cpp
  src/correlate/pack.cpp src/correlate/engine.cpp src/correlate/measurement.cpp src/correlate/two_model.cpp
  src/correlate/tests.cpp src/correlate/confirm.cpp src/correlate/core.cpp src/correlate/methods.cpp
  src/assign/membership.cpp src/assign/ranking.cpp src/assign/bias.cpp src/assign/cost.cpp src/assign/assign.cpp
  src/fuse/pack.cpp src/fuse/kinematics.cpp src/fuse/attributes.cpp src/fuse/engine.cpp
  src/quality/pack.cpp src/quality/input_clock.cpp src/quality/measures.cpp src/quality/rules.cpp
  src/quality/engine.cpp
  src/io/files.cpp src/io/function.cpp)
target_include_directories(goat_engine PUBLIC src)
target_compile_options(goat_engine PRIVATE -Wall -Wextra ${GOAT_FLOAT_FLAGS})

# tools/perf/README.md "Runner contract": the command-line runner
# (runner/build, runner/run).
add_executable(goat_runner src/io/runner.cpp)
target_link_libraries(goat_runner PRIVATE goat_engine)
target_compile_options(goat_runner PRIVATE -Wall -Wextra ${GOAT_FLOAT_FLAGS})

enable_testing()

# The conformance vectors, one runner per function (the names the perf
# harness times).
foreach(fn correlate filter fuse quality)
  if(fn STREQUAL "correlate")
    set(exe run_vectors)
    set(test vectors)
  else()
    set(exe run_${fn}_vectors)
    set(test ${fn}_vectors)
  endif()
  add_executable(${exe} test/run_vectors.cpp)
  target_link_libraries(${exe} PRIVATE goat_engine)
  target_compile_definitions(${exe} PRIVATE CORR_REPO_ROOT="${GOAT_REPO_ROOT}" VECTOR_FUNCTION="${fn}")
  target_compile_options(${exe} PRIVATE -Wall -Wextra ${GOAT_FLOAT_FLAGS})
  add_test(NAME ${test} COMMAND ${exe} "${GOAT_REPO_ROOT}")
endforeach()

# The engine's own tests: unit tests per module, property tests and the
# parser fuzzers (test/test_*.cpp), one executable, one ctest per module.
file(GLOB GOAT_UNIT_SOURCES CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/test/test_*.cpp)
add_executable(unit_tests test/unit_main.cpp ${GOAT_UNIT_SOURCES})
target_link_libraries(unit_tests PRIVATE goat_engine)
target_include_directories(unit_tests PRIVATE test)
target_compile_definitions(unit_tests PRIVATE CORR_REPO_ROOT="${GOAT_REPO_ROOT}"
                                              CORR_TEST_DIR="${CMAKE_CURRENT_SOURCE_DIR}/test")
target_compile_options(unit_tests PRIVATE -Wall -Wextra ${GOAT_FLOAT_FLAGS})
foreach(module extension)
  add_test(NAME unit_${module} COMMAND unit_tests ${module})
endforeach()
