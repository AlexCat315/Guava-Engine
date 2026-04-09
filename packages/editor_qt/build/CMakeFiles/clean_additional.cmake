# Additional clean files
cmake_minimum_required(VERSION 3.16)

if("${CONFIG}" STREQUAL "" OR "${CONFIG}" STREQUAL "Debug")
  file(REMOVE_RECURSE
  "CMakeFiles/GuavaEditor_autogen.dir/AutogenUsed.txt"
  "CMakeFiles/GuavaEditor_autogen.dir/ParseCache.txt"
  "GuavaEditor_autogen"
  )
endif()
