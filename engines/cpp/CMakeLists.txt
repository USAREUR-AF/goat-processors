cmake_minimum_required(VERSION 3.16)
project(goat_correlator_cpp CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

get_filename_component(CORR_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

add_library(correlator src/json.cpp src/kalman.cpp src/pack.cpp src/engine.cpp
            src/quality_pack.cpp src/quality.cpp)
target_include_directories(correlator PUBLIC src)
target_compile_options(correlator PRIVATE -Wall -Wextra)

add_executable(run_vectors test/run_vectors.cpp)
target_link_libraries(run_vectors PRIVATE correlator)
target_compile_definitions(run_vectors PRIVATE CORR_REPO_ROOT="${CORR_REPO_ROOT}")
target_compile_options(run_vectors PRIVATE -Wall -Wextra)

enable_testing()
add_test(NAME vectors COMMAND run_vectors "${CORR_REPO_ROOT}")

add_executable(assignment_test test/assignment_test.cpp)
target_link_libraries(assignment_test PRIVATE correlator)
target_compile_options(assignment_test PRIVATE -Wall -Wextra)
add_test(NAME assignment COMMAND assignment_test)

add_executable(run_quality_vectors test/run_quality_vectors.cpp)
target_link_libraries(run_quality_vectors PRIVATE correlator)
target_compile_definitions(run_quality_vectors PRIVATE CORR_REPO_ROOT="${CORR_REPO_ROOT}")
target_compile_options(run_quality_vectors PRIVATE -Wall -Wextra)
add_test(NAME quality_vectors COMMAND run_quality_vectors "${CORR_REPO_ROOT}")
