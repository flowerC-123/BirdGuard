cmake_minimum_required(VERSION 3.16)
project(birdguard_soc LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(Threads REQUIRED)
include(CTest)

option(BUILD_SYNCHRONOUS_BRIDGE "Build the synchronous UART bridge" OFF)
option(BUILD_RKNN_WORKER "Build the RKNN inference workers" OFF)

add_subdirectory(bridge)
if(BUILD_SYNCHRONOUS_BRIDGE)
    add_subdirectory(bridge_sync)
endif()
if(BUILD_RKNN_WORKER)
    add_subdirectory(worker)
endif()

if(BUILD_TESTING)
    foreach(name IN ITEMS parser_stream async_service)
        add_executable(test_${name} ../tests/soc/test_${name}.cpp)
        target_link_libraries(test_${name} PRIVATE roi_core)
        add_test(NAME ${name} COMMAND test_${name})
    endforeach()
    find_package(Python3 COMPONENTS Interpreter)
    if(Python3_Interpreter_FOUND)
        add_test(NAME bridge_stream COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/../tests/soc/test_bridge_stream.py
            --bridge $<TARGET_FILE:soc_uart_bridge>
            --output ${CMAKE_CURRENT_BINARY_DIR}/test_results)
    endif()
endif()
