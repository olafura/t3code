cmake_minimum_required(VERSION 3.21)
project(t3code-qt-runtime-tests LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui GuiPrivate Quick Test WebEngineQuick WebChannel)
enable_testing()
add_executable(tst_FolderExplorer tst_FolderExplorer.cpp ../../src/LocalFolderModel.cpp ../../src/ShellBridge.cpp ../../src/ThemeStore.cpp)
target_include_directories(tst_FolderExplorer PRIVATE ../../src)
target_compile_definitions(tst_FolderExplorer PRIVATE T3_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../.." T3_WEBCHANNEL_SCRIPT_URL="qrc:///qtwebchannel/qwebchannel.js")
target_link_libraries(tst_FolderExplorer PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Test)
add_test(NAME FolderExplorer COMMAND tst_FolderExplorer)
set_tests_properties(FolderExplorer PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software")
add_executable(tst_LocalFolderModel tst_LocalFolderModel.cpp ../../src/LocalFolderModel.cpp)
target_include_directories(tst_LocalFolderModel PRIVATE ../../src)
target_link_libraries(tst_LocalFolderModel PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Test)
add_test(NAME LocalFolderModel COMMAND tst_LocalFolderModel)
set_tests_properties(LocalFolderModel PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")
add_executable(tst_LocalTranscriber tst_LocalTranscriber.cpp ../../src/LocalTranscriber.cpp)
target_include_directories(tst_LocalTranscriber PRIVATE ../../src)
target_link_libraries(tst_LocalTranscriber PRIVATE Qt6::Core Qt6::Qml Qt6::Test)
add_test(NAME LocalTranscriber COMMAND tst_LocalTranscriber)
foreach(test_name IN ITEMS ShellRuntime ShellExamples AppViews)
  add_executable(tst_${test_name}
    tst_${test_name}.cpp
    ../../src/ShellRuntime.cpp
    ../../src/ShellBridge.cpp
    ../../src/ThemeStore.cpp
    ../../src/WebProfile.cpp
  )
  target_include_directories(tst_${test_name} PRIVATE ../../src)
  target_compile_definitions(tst_${test_name} PRIVATE
    T3_APP_VERSION="test"
    T3_WEBCHANNEL_SCRIPT_URL="qrc:///qtwebchannel/qwebchannel.js"
    T3_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../.."
  )
  target_link_libraries(tst_${test_name} PRIVATE
    Qt6::Core Qt6::Gui Qt6::GuiPrivate Qt6::Quick Qt6::Test Qt6::WebEngineQuick Qt6::WebChannel
  )
  if(APPLE)
    enable_language(OBJCXX)
    target_sources(tst_${test_name} PRIVATE ../../src/PlatformWindow.mm)
    target_link_libraries(tst_${test_name} PRIVATE "-framework AppKit")
  else()
    target_sources(tst_${test_name} PRIVATE ../../src/PlatformWindow.cpp)
  endif()
  add_test(NAME ${test_name} COMMAND tst_${test_name})
  set_tests_properties(${test_name} PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=;QT_QUICK_BACKEND=software")
endforeach()

qt_add_resources(tst_ShellExamples "shell_connector"
  PREFIX "/qt/qml/T3/Bricks"
  BASE "../../qml/T3/Bricks"
  FILES "../../qml/T3/Bricks/js/shell-connect.js"
)
target_sources(tst_ShellExamples PRIVATE ../../src/LocalFolderModel.cpp)

if(UNIX AND NOT APPLE)
  find_package(Qt6 6.9 REQUIRED COMPONENTS DBus)
  find_program(T3_DBUS_RUN_SESSION dbus-run-session REQUIRED)
  add_executable(tst_NativeNotifications tst_NativeNotifications.cpp ../../src/NativeNotifications.cpp)
  target_include_directories(tst_NativeNotifications PRIVATE ../../src)
  target_compile_definitions(tst_NativeNotifications PRIVATE T3_HAS_DBUS)
  target_link_libraries(tst_NativeNotifications PRIVATE Qt6::Core Qt6::Test Qt6::DBus)
  add_test(NAME NativeNotifications COMMAND "${T3_DBUS_RUN_SESSION}" -- $<TARGET_FILE:tst_NativeNotifications>)
endif()
