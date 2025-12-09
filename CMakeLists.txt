cmake_minimum_required(VERSION 3.0...3.14)

project(snap7)

include_directories(src/core)
include_directories(src/sys)
include_directories(src/lib)

file(GLOB_RECURSE SRC src/*.cpp release/wrappers/c-cpp/snap7.cpp)
file(GLOB_RECURSE HEADERS src/*.h release/wrappers/c-cpp/snap7.h)

if(WIN32)
	list(APPEND SRC src/lib/snap7.def)
endif()

add_library(snap7 SHARED ${HEADERS} ${SRC})

if(WIN32) 
	target_link_libraries(snap7 ws2_32 winmm)
else()
	target_link_libraries(snap7 pthread rt)
endif()

target_include_directories(snap7 PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/release/wrappers/c-cpp> $<INSTALL_INTERFACE:include>)

install(FILES release/wrappers/c-cpp/snap7.h DESTINATION include)
install(TARGETS snap7 EXPORT snap7 RUNTIME DESTINATION bin LIBRARY DESTINATION lib ARCHIVE DESTINATION lib)
install(EXPORT snap7 FILE snap7-config.cmake DESTINATION cmake)
