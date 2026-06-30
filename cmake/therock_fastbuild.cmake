# Copyright Advanced Micro Devices, Inc.
# SPDX-License-Identifier: MIT
#
# FASTBuild generator helpers for TheRock super-project and sub-projects.

# therock_fastbuild_resolve_gcc_tool(compiler tool_name out_path)
# Resolves a GCC helper (cc1, collect2, as, ...) to an absolute path if present.
function(therock_fastbuild_resolve_gcc_tool compiler tool_name out_path)
  set(_resolved "")
  execute_process(
    COMMAND "${compiler}" -print-file-name=${tool_name}
    OUTPUT_VARIABLE _candidate
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
  )
  if(_candidate AND IS_ABSOLUTE "${_candidate}" AND EXISTS "${_candidate}")
    set(_resolved "${_candidate}")
  endif()

  if(NOT _resolved)
    execute_process(
      COMMAND "${compiler}" -dumpmachine
      OUTPUT_VARIABLE _machine
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET
    )
    execute_process(
      COMMAND "${compiler}" -dumpversion
      OUTPUT_VARIABLE _version
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET
    )
    if(_machine AND _version)
      foreach(_root IN ITEMS "/usr/libexec/gcc" "/usr/lib/gcc")
        set(_guess "${_root}/${_machine}/${_version}/${tool_name}")
        if(EXISTS "${_guess}")
          set(_resolved "${_guess}")
          break()
        endif()
      endforeach()
    endif()
  endif()

  if(NOT _resolved)
    file(GLOB _globbed
      "/usr/libexec/gcc/*/*/${tool_name}"
      "/usr/lib/gcc/*/*/${tool_name}"
    )
    if(_globbed)
      list(GET _globbed 0 _resolved)
    endif()
  endif()

  if(NOT _resolved AND tool_name STREQUAL "as")
    execute_process(
      COMMAND "${compiler}" -dumpmachine
      OUTPUT_VARIABLE _machine
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET
    )
    if(_machine)
      foreach(_guess IN ITEMS "/usr/bin/${_machine}-as" "/usr/bin/as")
        if(EXISTS "${_guess}")
          set(_resolved "${_guess}")
          break()
        endif()
      endforeach()
    endif()
  endif()

  if(NOT _resolved AND tool_name STREQUAL "collect2")
    file(GLOB _collect2_globbed
      "/usr/libexec/gcc/*/*/collect2"
      "/usr/lib/gcc/*/*/collect2"
    )
    if(_collect2_globbed)
      list(GET _collect2_globbed 0 _resolved)
    endif()
  endif()

  set(${out_path} "${_resolved}" PARENT_SCOPE)
endfunction()

# therock_fastbuild_append_shared_libs(binary out_list)
# Appends absolute paths of shared libraries needed by a tool (via ldd).
function(therock_fastbuild_append_shared_libs binary out_list)
  if(NOT binary OR NOT EXISTS "${binary}")
    return()
  endif()
  execute_process(
    COMMAND sh -c "ldd '${binary}' 2>/dev/null | awk '/=> \\// {print $3}' | sort -u"
    OUTPUT_VARIABLE _ldd_output
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
  )
  if(NOT _ldd_output)
    return()
  endif()
  string(REPLACE "\n" ";" _ldd_libs "${_ldd_output}")
  foreach(_lib IN LISTS _ldd_libs)
    if(_lib AND EXISTS "${_lib}" AND NOT "${_lib}" IN_LIST ${out_list})
      list(APPEND ${out_list} "${_lib}")
    endif()
  endforeach()
  set(${out_list} ${${out_list}} PARENT_SCOPE)
endfunction()

# therock_fastbuild_append_tool_dir_files(dir out_list)
function(therock_fastbuild_append_tool_dir_files dir out_list)
  if(NOT dir OR NOT IS_DIRECTORY "${dir}")
    return()
  endif()
  file(GLOB _candidates "${dir}/*")
  foreach(_f IN LISTS _candidates)
    if(EXISTS "${_f}" AND NOT IS_DIRECTORY "${_f}")
      list(APPEND ${out_list} "${_f}")
    endif()
  endforeach()
  set(${out_list} ${${out_list}} PARENT_SCOPE)
endfunction()

# therock_fastbuild_collect_compiler_extra_files(compiler cxx_compiler out_var)
# Builds the list value for CMAKE_FASTBUILD_COMPILER_EXTRA_FILES.
function(therock_fastbuild_collect_compiler_extra_files compiler cxx_compiler out_var)
  set(_extra_files)

  therock_fastbuild_resolve_gcc_tool("${compiler}" cc1 _cc1_path)
  if(NOT _cc1_path)
    set(${out_var} "" PARENT_SCOPE)
    return()
  endif()

  get_filename_component(_cc1_dir "${_cc1_path}" DIRECTORY)
  therock_fastbuild_append_tool_dir_files("${_cc1_dir}" _extra_files)

  if(cxx_compiler)
    therock_fastbuild_resolve_gcc_tool("${cxx_compiler}" cc1plus _cc1plus_path)
    if(_cc1plus_path)
      get_filename_component(_cc1plus_dir "${_cc1plus_path}" DIRECTORY)
      if(NOT _cc1plus_dir STREQUAL _cc1_dir)
        therock_fastbuild_append_tool_dir_files("${_cc1plus_dir}" _extra_files)
      endif()
    endif()
  endif()

  therock_fastbuild_resolve_gcc_tool("${compiler}" collect2 _collect2_path)
  if(_collect2_path)
    list(APPEND _extra_files "${_collect2_path}")
    therock_fastbuild_append_shared_libs("${_collect2_path}" _extra_files)
  endif()

  therock_fastbuild_resolve_gcc_tool("${compiler}" as _as_path)
  if(_as_path)
    list(APPEND _extra_files "${_as_path}")
    therock_fastbuild_append_shared_libs("${_as_path}" _extra_files)
    execute_process(
      COMMAND "${compiler}" -dumpmachine
      OUTPUT_VARIABLE _machine
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET
    )
    # GCC invokes "as" by name; sync the generic driver name too (often a symlink).
    foreach(_as_alias IN ITEMS "/usr/bin/as" "/usr/bin/${_machine}-as")
      if(EXISTS "${_as_alias}" AND NOT "${_as_alias}" IN_LIST _extra_files)
        list(APPEND _extra_files "${_as_alias}")
      endif()
    endforeach()
  endif()

  if(_extra_files)
    list(REMOVE_DUPLICATES _extra_files)
  endif()
  set(${out_var} "${_extra_files}" PARENT_SCOPE)
endfunction()

# therock_fastbuild_setup_compiler_extra_files()
# When using the FASTBuild generator with distributed compiles, GCC needs cc1, as,
# and related tools synced to workers. Populate CMAKE_FASTBUILD_COMPILER_EXTRA_FILES
# if the user has not set it already.
function(therock_fastbuild_setup_compiler_extra_files)
  if(NOT CMAKE_GENERATOR STREQUAL "FASTBuild")
    return()
  endif()
  if(CMAKE_FASTBUILD_COMPILER_EXTRA_FILES)
    return()
  endif()
  if(NOT CMAKE_C_COMPILER)
    return()
  endif()

  therock_fastbuild_collect_compiler_extra_files(
    "${CMAKE_C_COMPILER}" "${CMAKE_CXX_COMPILER}" _extra_files)
  if(NOT _extra_files)
    message(WARNING
      "FASTBuild: could not locate GCC helper tools for ${CMAKE_C_COMPILER}; "
      "distributed compiles may fail on remote workers")
    return()
  endif()

  list(JOIN _extra_files ";" _joined)
  set(CMAKE_FASTBUILD_COMPILER_EXTRA_FILES "${_joined}" CACHE STRING
    "Extra compiler files for FASTBuild distributed compiles (auto-detected)" FORCE)
  if(NOT CMAKE_FASTBUILD_ENV_OVERRIDES)
    set(CMAKE_FASTBUILD_ENV_OVERRIDES "LD_LIBRARY_PATH=." CACHE STRING
      "FASTBuild remote tool environment overrides for distributed compiles" FORCE)
  endif()
  list(GET _extra_files 0 _cc1_hint)
  message(STATUS "FASTBuild: auto-set CMAKE_FASTBUILD_COMPILER_EXTRA_FILES (${_cc1_hint} ...)")
endfunction()
