#!/usr/bin/env bash

readonly SUCCESS=0
readonly ERROR=1
readonly DEBUG="set"
readonly APK1_PATH="${1}"
readonly APK1_NAME="$(echo ${APK1_PATH} | sed 's/.*\///' | sed 's/\..*//')"
readonly APK2_PATH="${2}"
readonly APK2_NAME="$(echo ${APK2_PATH} | sed 's/.*\///' | sed 's/\..*//')"
readonly OUTPUT_DIR="${3}"
readonly DEBUG_FILE="/tmp/bashapkdiff.log"
readonly TEMP_DIR="bashapkdiff_tmp"
CURRENT_COLUMNS=""
CLEAR_STRING="" 

# prints debug message to stdout
_DEBUG()
{
    if [[ "${DEBUG}" == "set" ]]; then
        local -r msg="${1}"
        echo "[[ $(caller 0) ]]:  ${1}" >> ${DEBUG_FILE}
    fi
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
    if [[ "${CURRENT_COLUMNS}" != "${COLUMNS}" ]]; then
        CURRENT_COLUMNS="${COLUMNS}"
        CLEAR_STRING=""
        for progress_counter in $(seq 1 ${COLUMNS}); do
            CLEAR_STRING+=" "
        done
    fi

    local -r msg="${1}"
    echo -ne "${CLEAR_STRING}\r"
    echo -ne "${msg:0:${CURRENT_COLUMNS}}\r"
    
}

_PRINT_ARRAY()
{
    declare -a input_array=("${!1}")
    local -r file_path="${2}"
    for entry in ${input_array[@]}; do
        echo "${entry}" >> ${file_path}
    done
}


# prints to output_file
_OUTPUT()
{
    echo -e "${1}" >> ${OUTPUT_DIR}/global_res.txt
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

    local i=1
    local -r dex_list_size=${#dex_list[@]}
    for dex in ${dex_list[@]}; do
        local dex_output_dir="${dex%????}"
        _PROGRESS "Decompiling (${i} of ${dex_list_size}): ${dex}"
        # ignore jadx's result
        jadx -q --show-bad-code --output-dir ${dex_output_dir} ${dex}
        
        cp -r ${dex_output_dir}/sources/* "${output_dir}"
        _E_PROCESS "couldn't copy jadx results"
        _DEBUG "Decompiled ${dex}"
        rm -rf ${dex_output_dir}
        i=$(( i + 1 ))
    done
    
    return ${SUCCESS}
}

# Compares all files in specified directories with specified mask (based on sha256 hashes)
# Sets COMP_DIR1_FILES and COMP_DIR2_FILES with files in according directories
# If file_path exists in both directories and their hashes natch,
#+ file_path is saved in COMP_SHARED_IDENTICAL
# If file_path exists in both directories and their hashes differ,
#+ file_path is saved in DCOMP_SHARED_DIFFERENT
# Important! Arrays are filled with relative file paths!
# COMP_DIR1_UNIQUE and COMP_DIR2_UNIQUE computed in the end
# Globals:
#   writes COMP_DIR1_FILES       -> array of strings
#   writes COMP_DIR2_FILES       -> array of strings
#   writes COMP_DIR1_UNIQUE      -> array of strings
#   writes COMP_DIR2_UNIQUE      -> array of strings
#   writes COMP_SHARED_IDENTICAL -> array of strings
#   writes COMP_SHARED_DIFFERENT -> array of strings
# Arguments:
#   1. Path to dir1              -> string
#   2. Path to dir2              -> string
#   3. Path to output file       -> string
#   4. OPTIONAL filemask         -> string
_COMP_DIRS()
{
    local -r dir1_dir="${1}"
    local -r dir2_dir="${2}"
    local -r output_dir="${3}"
    local -r file_mask="${4}"
    
    if [[ ! -d "${dir1_dir}" ]]; then
        _DEBUG "Missing ${dir1_dir} dir"
        return ${ERROR}
    elif [[ ! -d "${dir2_dir}" ]]; then
        _DEBUG "Missing ${dir2_dir} dir"
        return ${ERROR}
    fi
    
    if [[ -d "${output_dir}" ]]; then
        _DEBUG "${output_dir} exists"
        return ${ERROR}
    fi
    
    mkdir "${output_dir}"
    _E_PROCESS "Couldn't create ${output_dir}"

    _DEBUG "Arranging COMP_DIR1_FILES array"
    cd "${dir1_dir}"
    _E_PROCESS "cd failed"
    
    if [[ "${file_mask}" != "" ]]; then
        COMP_DIR1_FILES=($(find . -type f -iname "${file_mask}"))
    else
        COMP_DIR1_FILES=($(find . -type f))
    fi

    cd - > /dev/null

    _DEBUG "Arranging COMP_DIR2_FILES array"
    cd "${dir2_dir}"
    _E_PROCESS "cd failed"

    if [[ "${file_mask}" != "" ]]; then
        COMP_DIR2_FILES=($(find . -type f -iname "${file_mask}"))
    else
        COMP_DIR2_FILES=($(find . -type f))
    fi
    cd - > /dev/null

    if [[ ${#COMP_DIR1_FILES[@]} == 0 ]]; then
        _DEBUG "no files found in ${dir1_dir}"
        return ${ERROR}
    elif [[ ${#COMP_DIR2_FILES[@]} == 0 ]]; then
        _DEBUG "no files found in ${dir2_dir}"
        return ${ERROR}
    fi
    
    COMP_SHARED_IDENTICAL=()
    COMP_SHARED_DIFFERENT=()


    _MSG "Initiated comp for ${dir1_dir} and ${dir2_dir} directories"
    local i=1
    local -r comp_dir1_files_size=${#COMP_DIR1_FILES[@]}
    for file_path in ${COMP_DIR1_FILES[@]}; do
        _PROGRESS "Comparing(${i} in ${comp_dir1_files_size}): ${file_path}"
        
        if [[ ! -f "${dir2_dir}/${file_path}" ]]; then
            continue
        fi
        
        if [[ "$(sha256sum "${dir1_dir}/${file_path}")" == \
              "$(sha256sum "${dir2_dir}/${file_path}")" ]]
        then
            COMP_SHARED_IDENTICAL+=("${file_path}")
        else
            COMP_SHARED_DIFFERENT+=("${file_path}")
        fi
        i=$(( i + 1 ))
    done
    
    # get unique
    COMP_DIR1_UNIQUE=($(echo ${COMP_DIR1_FILES[@]} \
                 ${COMP_SHARED_DIFFERENT[@]} \
                 ${COMP_SHARED_IDENTICAL[@]}\
                 | tr ' ' '\n' \
                 | sort \
                 | uniq -u))
    
    COMP_DIR2_UNIQUE=($(echo ${COMP_DIR2_FILES[@]} \
                 ${COMP_SHARED_DIFFERENT[@]} \
                 ${COMP_SHARED_IDENTICAL[@]}\
                 | tr ' ' '\n' \
                 | sort \
                 | uniq -u))

    if [[ "${file_mask}" != "" ]]; then
        _OUTPUT "###### COMP RES FOR MASK [[ ${file_mask} ]] ######"
    else
        _OUTPUT "###### COMP RES FOR ${dir1_dir} and ${dir2_dir} ######" 
    fi
    _OUTPUT "### Stats for ${dir1_dir} ###"
    _OUTPUT "Total compared files: ${#COMP_DIR1_FILES[@]}"
    _OUTPUT "Unique files: ${#COMP_DIR1_UNIQUE[@]}"
    _OUTPUT "### Stats for ${dir2_dir} ###"
    _OUTPUT "Total compared files: ${#COMP_DIR2_FILES[@]}"
    _OUTPUT "Unique files: ${#COMP_DIR2_UNIQUE[@]}"
    _OUTPUT "### Shared stats ###"
    _OUTPUT "Shared files: $((${#COMP_SHARED_DIFFERENT[@]} + ${#COMP_SHARED_IDENTICAL[@]} ))"
    _OUTPUT "Identical files in shared: ${#COMP_SHARED_IDENTICAL[@]}"
    _OUTPUT "Different files in shared: ${#COMP_SHARED_DIFFERENT[@]}"
    _OUTPUT "######==========================================######" 

    if [[ ${#COMP_SHARED_DIFFERENT[@]} != 0 ]]; then
        _PRINT_ARRAY COMP_SHARED_DIFFERENT[@] "${output_dir}/comp_shared_different.txt"
    fi
    if [[ ${#COMP_SHARED_IDENTICAL[@]} != 0 ]]; then
        _PRINT_ARRAY COMP_SHARED_IDENTICAL[@] "${output_dir}/comp_shared_identical.txt"
    fi
    if [[ ${#COMP_DIR1_UNIQUE[@]} != 0 ]]; then
        _PRINT_ARRAY COMP_DIR1_UNIQUE[@] "${output_dir}/comp_${APK1_NAME}_unique.txt"
    fi
    if [[ ${#COMP_DIR2_UNIQUE[@]} != 0 ]]; then
        _PRINT_ARRAY COMP_DIR2_UNIQUE[@] "${output_dir}/comp_${APK2_NAME}_unique.txt"
    fi

    return ${SUCCESS}
}

# Diffs all files in specified directories with specified mask (based on diff util)
# Sets DIFF1_DIR1_FILES and DIFF_DIR2_FILES with all files in according directories
# If file_path exists in both directories and they are identical,
#+ file_path is saved in DIFF_SHARED_IDENTICAL
# If file_path exists in both directories and they are different,
#+ file_path is saved in DIFF_SHARED_DIFFERENT
# Writes resultive diffs to output_file_path 
# Important! Arrays are filled with relative file paths!
# DIFF_DIR1_UNIQUE and DIFF_DIR2_UNIQUE computed in the end
# Globals:
#   writes DIFF_DIR1_FILES       -> array of strings
#   writes DIFF_DIR2_FILES       -> array of strings
#   writes DIFF_DIR1_UNIQUE      -> array of strings
#   writes DIFF_DIR2_UNIQUE      -> array of strings
#   writes DIFF_SHARED_IDENTICAL -> array of strings
#   writes DIFF_SHARED_DIFFERENT -> array of strings
# Arguments:
#   1. Path to dir1              -> string
#   2. Path to dir2              -> string
#   3. Path to output file       -> string
#   4. OPTIONAL filemask         -> string
_DIFF_DIRS()
{
    local -r dir1_dir="${1}"
    local -r dir2_dir="${2}"
    local -r output_dir="${3}"
    local -r file_mask="${4}"
    local -r output_diff_path="${output_dir}/diff_output.txt"
    
    if [[ ! -d "${dir1_dir}" ]]; then
        _DEBUG "Missing ${dir1_dir} dir"
        return ${ERROR}
    elif [[ ! -d "${dir2_dir}" ]]; then
        _DEBUG "Missing ${dir2_dir} dir"
        return ${ERROR}
    fi
    
    if [[ -d "${output_dir}" ]]; then
        _DEBUG "${output_dir} exists"
        return ${ERROR}
    fi
    
    mkdir "${output_dir}"
    _E_PROCESS "Couldn't create ${output_dir}"

    _DEBUG "Arranging DIFF_DIR1_FILES array"
    cd "${dir1_dir}"
    _E_PROCESS "cd failed"
    
    if [[ "${file_mask}" != "" ]]; then
        DIFF_DIR1_FILES=($(find . -type f -iname "${file_mask}"))
    else
        DIFF_DIR1_FILES=($(find . -type f))
    fi
    cd - > /dev/null

    _DEBUG "arranging DIFF_DIR2_FILES array"
    cd "${dir2_dir}"
    _E_PROCESS "cd failed"

    if [[ "${file_mask}" != "" ]]; then
        DIFF_DIR2_FILES=($(find . -type f -iname "${file_mask}"))
    else
        DIFF_DIR2_FILES=($(find . -type f))
    fi
    cd - > /dev/null

    if [[ ${#DIFF_DIR1_FILES[@]} == 0 ]]; then
        _DEBUG "no files found in dir1_dir"
        return ${ERROR}
    elif [[ ${#DIFF_DIR2_FILES[@]} == 0 ]]; then
        _DEBUG "no files found in dir2_dir"
        return ${ERROR}
    fi
    
    local diff_output_path="${TEMP_DIR}/diff_temp"
    DIFF_SHARED_IDENTICAL=()
    DIFF_SHARED_DIFFERENT=()

    _MSG "Initiated diff for ${dir1_dir} and ${dir2_dir} directories"
    local i=1
    local -r diff_dir1_files_size=${#DIFF_DIR1_FILES[@]}
    for file_path in ${DIFF_DIR1_FILES[@]}; do
        _PROGRESS "Diffing(${i} in ${diff_dir1_files_size}): ${file_path}"
        
        diff "${dir1_dir}/${file_path}" \
             "${dir2_dir}/${file_path}" > ${diff_output_path}
        local res="${?}"

        if [[ "${res}" == "2" ]]; then
            _DEBUG "${file_path} not found in dir2"
        elif [[ "${res}" == "1" ]]; then
            _DEBUG "${file_path} differs"
            DIFF_SHARED_DIFFERENT+=("${file_path}")
            cat ${diff_output_path} >> "${output_diff_path}"
        elif [[ "${res}" == "0" ]]; then
            _DEBUG "${file_path} is identical"
            DIFF_SHARED_IDENTICAL+=("${file_path}")
        fi
        i=$(( i + 1 ))
    done
    
    # get unique
    DIFF_DIR1_UNIQUE=($(echo ${DIFF_DIR1_FILES[@]} \
                 ${DIFF_SHARED_DIFFERENT[@]} \
                 ${DIFF_SHARED_IDENTICAL[@]}\
                 | tr ' ' '\n' \
                 | sort \
                 | uniq -u))
    
    DIFF_DIR2_UNIQUE=($(echo ${DIFF_DIR2_FILES[@]} \
                 ${DIFF_SHARED_DIFFERENT[@]} \
                 ${DIFF_SHARED_IDENTICAL[@]}\
                 | tr ' ' '\n' \
                 | sort \
                 | uniq -u))
    if [[ "${file_mask}" != "" ]]; then
        _OUTPUT "###### DIFF RES FOR FILEMASK ${file_mask} ######"
    else
        _OUTPUT "###### DIFF RES FOR ${dir1_dir} and ${dir2_dir} ######" 
    fi
    _OUTPUT "### Stats for ${dir1_dir} ###"
    _OUTPUT "Total decompiled files: ${#DIFF_DIR1_FILES[@]}"
    _OUTPUT "Unique files: ${#DIFF_DIR1_UNIQUE[@]}"
    _OUTPUT "### Stats for ${dir2_dir} ###"
    _OUTPUT "Total decompiled files: ${#DIFF_DIR2_FILES[@]}"
    _OUTPUT "Unique files: ${#DIFF_DIR2_UNIQUE[@]}"
    _OUTPUT "### Shared stats ###"
    _OUTPUT "Shared files: $((${#DIFF_SHARED_DIFFERENT[@]} + ${#DIFF_SHARED_IDENTICAL[@]} ))"
    _OUTPUT "Identical files in shared: ${#DIFF_SHARED_IDENTICAL[@]}"
    _OUTPUT "Different files in shared: ${#DIFF_SHARED_DIFFERENT[@]}"
    _OUTPUT "######==========================================######" 

    if [[ ${#DIFF_SHARED_DIFFERENT[@]} != 0 ]]; then
        _PRINT_ARRAY DIFF_SHARED_DIFFERENT[@] "${output_dir}/diff_shared_different.txt"
    fi
    if [[ ${#DIFF_SHARED_IDENTICAL[@]} != 0 ]]; then
        _PRINT_ARRAY DIFF_SHARED_IDENTICAL[@] "${output_dir}/diff_shared_identical.txt"
    fi
    if [[ ${#DIFF_DIR1_UNIQUE[@]} != 0 ]]; then
        _PRINT_ARRAY DIFF_DIR1_UNIQUE[@] "${output_dir}/diff_${APK1_NAME}_unique.txt"
    fi
    if [[ ${#DIFF_DIR2_UNIQUE[@]} != 0 ]]; then
        _PRINT_ARRAY DIFF_DIR2_UNIQUE[@] "${output_dir}/diff_${APK2_NAME}_unique.txt"
    fi

    return ${SUCCESS}
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

# defines for directory structure
apk1_unzipped_dir="${TEMP_DIR}/${APK1_PATH%????}"
apk2_unzipped_dir="${TEMP_DIR}/${APK2_PATH%????}"
apk1_decompiled_dir="${TEMP_DIR}/${APK1_PATH%????}_decompiled"
apk2_decompiled_dir="${TEMP_DIR}/${APK2_PATH%????}_decompiled"


rm -rf "${TEMP_DIR}"
_E_PROCESS "Failed to remove ${TEMP_DIR}"
rm -rf "${OUTPUT_DIR}"
_E_PROCESS "Failed to remove ${OUTPUT_DIR}"

mkdir "${TEMP_DIR}" > /dev/null
_E_PROCESS "Failed to create temporary dir"
mkdir "${OUTPUT_DIR}" >/dev/null
_E_PROCESS "Failed to create output dir"

_UNPACK_APK "${APK1_PATH}" "${apk1_unzipped_dir}"
_E_PROCESS "_UNPACK_APK failed for ${APK1_PATH}"
_UNPACK_APK "${APK2_PATH}" "${apk2_unzipped_dir}"
_E_PROCESS "_UNPACK_APK failed for ${APK2_PATH}"

_ARRANGE_DEX_CLASSES "${apk1_unzipped_dir}" "${apk1_decompiled_dir}"
_E_PROCESS "ARRANGE_DEX_CLASSES failed for apk1"

_ARRANGE_DEX_CLASSES "${apk1_unzipped_dir}" "${apk2_decompiled_dir}"
_E_PROCESS "ARRANGE_DEX_CLASSES failed for apk2"

_DIFF_DIRS "${apk1_decompiled_dir}" "${apk2_decompiled_dir}" "${OUTPUT_DIR}/jadx_diff"

_COMP_DIRS "${apk1_unzipped_dir}/res" "${apk2_unzipped_dir}/res" "${OUTPUT_DIR}/res_comp"

_DIFF_DIRS "${apk1_unzipped_dir}" "${apk2_unzipped_dir}" "${OUTPUT_DIR}/properties_diff" "*.properties"
_COMP_DIRS "${apk1_unzipped_dir}/assets" "${apk2_unzipped_dir}/assets" "${OUTPUT_DIR}/assets_comp"

