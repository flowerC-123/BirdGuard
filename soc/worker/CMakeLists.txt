if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "RKNN workers target Linux on RV1126B.")
endif()

set(RKNN_LIBRARY "" CACHE FILEPATH "Path to the RV1126B RKNN runtime library")
set(RKNN_INCLUDE_DIR "" CACHE PATH "Directory containing rknn_api.h")
if(NOT EXISTS "${RKNN_LIBRARY}")
    message(FATAL_ERROR "Set RKNN_LIBRARY to the RKNN runtime library.")
endif()
if(NOT EXISTS "${RKNN_INCLUDE_DIR}/rknn_api.h")
    message(FATAL_ERROR "Set RKNN_INCLUDE_DIR to the RKNN headers directory.")
endif()
find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs)

foreach(entry IN ITEMS single persistent)
    add_executable(bird_${entry}_image
        app/${entry}_image.cpp app/console_log.cpp
        vendor/yolov8/yolov8.cpp vendor/yolov8/postprocess.cpp
        vendor/yolov8/file_utils.cpp)
    target_include_directories(bird_${entry}_image PRIVATE
        app vendor/yolov8 vendor/log "${RKNN_INCLUDE_DIR}" ${OpenCV_INCLUDE_DIRS})
    target_link_libraries(bird_${entry}_image PRIVATE "${RKNN_LIBRARY}" ${OpenCV_LIBS} m)
    set_target_properties(bird_${entry}_image PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
endforeach()
