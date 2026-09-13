include_guard(GLOBAL)

if(APPLE)
  include(FetchContent)
  # QQuickWindow needs the native-view backend, not the QWidget wrapper.
  # Its internal C interface is coupled to this exact upstream revision.
  FetchContent_Declare(qt_liquid_glass
    GIT_REPOSITORY https://github.com/fsalinas26/qt-liquid-glass.git
    GIT_TAG 3b109e4de93f370f7e7b90d1b8f005c33a7657c3
    SOURCE_SUBDIR native-backend-only
  )
  FetchContent_MakeAvailable(qt_liquid_glass)
  add_library(t3_liquid_glass STATIC "${qt_liquid_glass_SOURCE_DIR}/src/QtLiquidGlass.mm")
  target_include_directories(t3_liquid_glass PUBLIC "${qt_liquid_glass_SOURCE_DIR}/src")
  target_link_libraries(t3_liquid_glass PRIVATE "-framework AppKit" "-framework Foundation")
endif()

function(t3_target_platform_window target)
  if(APPLE)
    target_sources(${target} PRIVATE "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../src/PlatformWindow.mm")
    target_link_libraries(${target} PRIVATE t3_liquid_glass "-framework AppKit")
  else()
    target_sources(${target} PRIVATE "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../src/PlatformWindow.cpp")
  endif()
endfunction()
