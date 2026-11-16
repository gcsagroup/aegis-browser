cmake_minimum_required(VERSION 3.21)
project(aegis_access LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(overlay "${CMAKE_CURRENT_SOURCE_DIR}/../overlay")
set(component "${overlay}/components/aegis_access")
set(manifest "${component}/access_sources.json")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${manifest}")
file(READ "${manifest}" access_sources)

string(JSON core GET "${access_sources}" core)
string(JSON module_count LENGTH "${core}")
math(EXPR last_module "${module_count} - 1")
set(core_sources "")
foreach(index RANGE "${last_module}")
  string(JSON name MEMBER "${core}" "${index}")
  string(JSON count LENGTH "${core}" "${name}")
  math(EXPR last_source "${count} - 1")
  foreach(source_index RANGE "${last_source}")
    string(JSON path GET "${core}" "${name}" "${source_index}")
    list(APPEND core_sources "${component}/${path}")
  endforeach()
endforeach()

add_library(aegis_access_core STATIC ${core_sources})
target_include_directories(aegis_access_core PUBLIC "${overlay}")

include(CTest)
if(BUILD_TESTING)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  set(vector_outputs "")
  foreach(name IN ITEMS route_planner_vectors policy_matcher_vectors)
    string(JSON script GET "${access_sources}" "${name}" script)
    string(JSON input GET "${access_sources}" "${name}" input)
    string(JSON output GET "${access_sources}" "${name}" output)
    set(output "${CMAKE_CURRENT_BINARY_DIR}/${output}")
    add_custom_command(
      OUTPUT "${output}"
      COMMAND Python3::Interpreter "${component}/${script}"
              "${component}/${input}" "${output}"
      DEPENDS "${component}/${script}" "${component}/${input}"
      VERBATIM
    )
    list(APPEND vector_outputs "${output}")
  endforeach()

  string(JSON test_main GET "${access_sources}" test_main)
  string(JSON test_support GET "${access_sources}" test_support source)
  string(JSON test_support_header GET "${access_sources}" test_support header)
  add_executable(aegis_access_native_test "${component}/${test_main}"
                 "${component}/${test_support}" "${component}/${test_support_header}"
                 ${vector_outputs})
  target_include_directories(aegis_access_native_test PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
  target_link_libraries(aegis_access_native_test PRIVATE aegis_access_core)
  if(ANDROID)
    add_test(NAME aegis_access_contract
             COMMAND Python3::Interpreter "${CMAKE_CURRENT_SOURCE_DIR}/run_android_test.py"
                     "$<TARGET_FILE:aegis_access_native_test>"
                     "${ANDROID_ABI}" "${CMAKE_SYSTEM_VERSION}")
  else()
    add_test(NAME aegis_access_contract COMMAND aegis_access_native_test)
  endif()
  set_tests_properties(aegis_access_contract PROPERTIES TIMEOUT 210)
endif()
