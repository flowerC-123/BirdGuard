add_library(roi_sync_core
    src/roi_protocol.cpp
    src/roi_service.cpp
    src/platform_common.cpp)
target_include_directories(roi_sync_core PUBLIC include)
target_link_libraries(roi_sync_core PUBLIC Threads::Threads)

add_executable(soc_uart_bridge_sync src/main_uart.cpp src/platform_posix.cpp)
target_link_libraries(soc_uart_bridge_sync PRIVATE roi_sync_core)
set_target_properties(soc_uart_bridge_sync PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
if(UNIX)
    target_compile_definitions(soc_uart_bridge_sync PRIVATE _DEFAULT_SOURCE)
endif()
