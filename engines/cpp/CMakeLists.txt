cmake_minimum_required(VERSION 3.16)
project(goat_correlator_cpp CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

get_filename_component(CORR_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

add_library(correlator src/json.cpp src/report.cpp src/pack.cpp src/track.cpp src/engine.cpp)
target_include_directories(correlator PUBLIC src)
target_compile_options(correlator PRIVATE -Wall -Wextra)

# fuse.md: its own module beside correlate, reusing the shared filter in
# track.cpp and the report reading in report.cpp.
add_library(fuse src/fuse_pack.cpp src/fuse.cpp)
target_link_libraries(fuse PUBLIC correlator)
target_compile_options(fuse PRIVATE -Wall -Wextra)

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

add_executable(run_fuse_vectors test/run_fuse_vectors.cpp)
target_link_libraries(run_fuse_vectors PRIVATE fuse)
target_compile_definitions(run_fuse_vectors PRIVATE CORR_REPO_ROOT="${CORR_REPO_ROOT}")
target_compile_options(run_fuse_vectors PRIVATE -Wall -Wextra)
add_test(NAME fuse_vectors COMMAND run_fuse_vectors "${CORR_REPO_ROOT}")

# The filter (spec/filter.md), its own library beside the correlator; it
# shares json, report (correlate.md "Reports") and PackError.
add_library(filter src/filter_pack.cpp src/filter.cpp)
target_include_directories(filter PUBLIC src)
target_link_libraries(filter PUBLIC correlator)
target_compile_options(filter PRIVATE -Wall -Wextra)

add_executable(run_filter_vectors test/run_filter_vectors.cpp)
target_link_libraries(run_filter_vectors PRIVATE filter)
target_compile_definitions(run_filter_vectors PRIVATE CORR_REPO_ROOT="${CORR_REPO_ROOT}")
target_compile_options(run_filter_vectors PRIVATE -Wall -Wextra)
add_test(NAME filter_vectors COMMAND run_filter_vectors "${CORR_REPO_ROOT}")
