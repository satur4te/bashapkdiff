#!/usr/bin/env bash

readonly SUCCESS=0
readonly ERROR=1
readonly APK1_PATH="${1}"
readonly APK2_PATH="${2}"
readonly OUTPUT_FILE="${3}"
readonly DEBUG_FILE="/tmp/bashapkdiff.log"
readonly TEMP_DIR="bashapkdiff_tmp"
# to make this work we need to:
# 1. unzip apks to dirs
# 2. unpack all classes folders with jadx
# 3. arrange them in single folder with sources
# 4. diff one by one
# 5. profit
#
#

# prints debug message to stdout
_DEBUG()
{
    local -r msg="${1}"
    echo "[[ $(caller 0) ]]:  ${1}" >> ${DEBUG_FILE}
}

# prints user message to stdout
_MSG()
{
    local -r msg="${1}"
    echo -e "${1}"
}
# prints progress (commands are on the same line)
_PROGRESS()
{
    local -r msg="${1}"

    echo -ne "${1}\r"
}


# prints to output_file
_OUTPUT()
{
    echo -e "${1}" >> ${OUTPUT_FILE}
}

# processes last command's exit code and exits with message if not SUCCESS
_E_PROCESS()
{
    local -r exitcode="${?}"
    local -r msg="${1}"
    if [[ "${exitcode}" != "${SUCCESS}" ]]; then
        _DEBUG "${msg}"
        exit ${ERROR}
    fi
}

# unpacks apk to a specified dir
# arguments:
#   1. path to apk
#   2. path to output dir
_UNPACK_APK()
{
    local -r path_to_apk="${1}"
    local -r output_dir="${2}" 
    
    if [[ ! -f "${path_to_apk}" ]]; then
        _DEBUG "${path_to_apk} apk was not found"
        return ${ERROR}
    fi

    if [[ -d ${output_dir} ]]; then
        _DEBUG "found dir ${output_dir}"
        _DEBUG "delete the folder and rerun the program"
        return ${ERROR}
    fi

    _MSG "Unzipping ${path_to_apk} to ${output_dir}"
    unzip -q ${path_to_apk} -d ${output_dir}
    _E_PROCESS "Unzip failed!"

    return ${SUCCESS}
}

# decompiles .dex files with jadx and arranges them in single folder
# arguments:
#   1. path to unpacked apk
#   2. path to output dir
_ARRANGE_DEX_CLASSES()
{
    local -r input_dir="${1}"
    local -r output_dir="${2}"
    
    if [[ ! -d ${input_dir} ]]; then
        _DEBUG "missing directory with .dex files"
        return ${ERROR}
    fi

    if [[ ! -d ${output_dir} ]]; then
        mkdir -p ${output_dir}
        _E_PROCESS "cannot create output_dir"
    fi

    #_DEBUG "output dir already exists"

    dex_list=($(ls ${input_dir}/*.dex))

    if [[ ${#dex_list[@]} == 0 ]]; then
        _DEBUG "couldn't find any dex filex"
        return ${ERROR}
    fi

    for dex in ${dex_list[@]}; do
        local dex_output_dir="${dex%????}"
        _PROGRESS "Decompiling: ${dex}"
        # ignore jadx's result
        jadx -q --output-dir ${dex_output_dir} ${dex}
        
        cp -r ${dex_output_dir}/sources/* "${output_dir}"
        _E_PROCESS "couldn't copy jadx results"
        _DEBUG "Decompiled ${dex}"
        rm -rf ${dex_output_dir}
    done
    
    return ${SUCCESS}
}

# diffs sources and writes results to OUTPUT_FILE
# arguments:
#   1. path to sources of apk1
#   2. path to sources of apk2
_DIFF_DECOMPILED()
{
    local -r apk1_dir="${1}"
    local -r apk2_dir="${2}"
    if [[ ! -d ${apk1_dir} ]]; then
        _DEBUG "missing apk1 dir"
        return ${ERROR}
    elif [[ ! -d ${apk2_dir} ]]; then
        _DEBUG "missing apk2 dir"
        return ${ERROR}
    fi
    
    _DEBUG "Arranging apk1_files array"
    cd ${apk1_dir}
    apk1_files=($(find . -type f))
    cd - > /dev/null

    _DEBUG "Arranging apk2_files array"
    cd ${apk2_dir}
    apk2_files=($(find . -type f))
    cd - > /dev/null

    # save lengths for stats
    local -r apk1_files_count="${#apk1_files[@]}"
    local -r apk2_files_count="${#apk2_files[@]}"
    local apk_shared_files=()

    if [[ ${#apk1_files[@]} == 0 ]]; then 
        _DEBUG "no files found in apk1_dir"
        return ${ERROR}
    elif [[ ${#apk2_files[@]} == 0 ]]; then
        _DEBUG "no files found in apk2_dir"
        return ${ERROR}
    fi
    
    local apk_shared_count=0
    local apk_shared_identical_count=0
    local apk1_unique_count=0
    local apk2_unique_count=0

    DIFF_OUTPUT_PATH="${TEMP_DIR}/diff_temp"
    for file_path in ${apk1_files[@]}; do
        _PROGRESS "Diffing ${file_path}"
        
        diff "${apk1_dir}/${file_path}" "${apk2_dir}/${file_path}" > ${DIFF_OUTPUT_PATH} 
        local res="${?}"

        if [[ "${res}" == "2" ]]; then
            _DEBUG "${file_path} is missing in some apk"
            apk1_unique_count=$(( ${apk1_unique_count} + 1 ))
        elif [[ "${res}" == "1" ]]; then
            _DEBUG "${file_path} are different for apks, diff initiated"
            apk_shared_count=$(( ${apk_shared_count} + 1 ))
            _OUTPUT "### DIFF RESULT FOR ${file_path} ###"
            cat ${DIFF_OUTPUT_PATH} >> ${OUTPUT_FILE}
        elif [[ "${res}" == "0" ]]; then
            _DEBUG "${file_path} is identical for both apks"
            apk_shared_count=$(( ${apk_shared_count} + 1 ))
            apk_shared_identical_count=$(( ${apk_shared_identical_count} + 1 ))
        fi
    done
    
    _OUTPUT "### Stats for ${APK1_PATH} ###"
    _OUTPUT "Total decompiled files: ${apk1_files_count}"
    _OUTPUT "Unique files: ${apk1_unique_count}"
    _OUTPUT "### Stats for ${APK2_PATH} ###"
    _OUTPUT "Total decompiled files: ${apk2_files_count}"
    _OUTPUT "Unique files: $(( ${apk2_files_count} - ${apk_shared_count} ))"
    _OUTPUT "### Shared stats ###"
    _OUTPUT "Shared files: ${apk_shared_count}"
    _OUTPUT "Identical files in shared: ${apk_shared_identical_count}"
    _OUTPUT "Different files in shared: $(( ${apk_shared_count} - ${apk_shared_identical_count} ))"
}

### EXECUTION STARTS HERE ###

if [[ -z ${1} ]]        ||
   [[ -z ${2} ]]        ||
   [[ -z ${3} ]]        ||
   [[ "${1}" == "-h" ]] ||
   [[ "${1}" == "--help" ]]
then
    _MSG "bashapkdiff - allows you to diff apks' source code (uses jadx for decompilation)"
    _MSG "arguments:"
    _MSG "  1. path to apk1"
    _MSG "  2. path to apk2"
    _MSG "  1. path to output file with per-file diff results and stats"
    exit ${ERROR}
fi

_DEBUG "Initiated bashapkdiff run ($(date))"
# _MSG "Path to apk1: ${APK1_PATH}"
# _MSG "Path to apk2: ${APK2_PATH}"
# _MSG "Path to output_file: ${OUTPUT_FILE}"

# defines for directory structure
apk1_unzipped_dir="${TEMP_DIR}/${APK1_PATH%????}"
apk2_unzipped_dir="${TEMP_DIR}/${APK2_PATH%????}"
apk1_decompiled_dir="${TEMP_DIR}/${APK1_PATH%????}_decompiled"
apk2_decompiled_dir="${TEMP_DIR}/${APK2_PATH%????}_decompiled"


#create tmp folder
rm -rf "${TEMP_DIR}"
rm -rf "${OUTPUT_FILE}"

mkdir "${TEMP_DIR}"
_E_PROCESS "Failed to create temporary folder"

_UNPACK_APK "${APK1_PATH}" "${apk1_unzipped_dir}"
_E_PROCESS "_UNPACK_APK failed for ${APK1_PATH}"
_UNPACK_APK "${APK2_PATH}" "${apk2_unzipped_dir}"
_E_PROCESS "_UNPACK_APK failed for ${APK2_PATH}"

_ARRANGE_DEX_CLASSES "${apk1_unzipped_dir}" "${apk1_decompiled_dir}"
_E_PROCESS "ARRANGE_DEX_CLASSES failed for apk1"

_ARRANGE_DEX_CLASSES "${apk1_unzipped_dir}" "${apk2_decompiled_dir}"
_E_PROCESS "ARRANGE_DEX_CLASSES failed for apk2"

_DIFF_DECOMPILED "${apk1_decompiled_dir}" "${apk2_decompiled_dir}"
