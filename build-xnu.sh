# 2k20 ~antoniofrighetto
# Build any XNU kernel version. Make sure you have the related MacOSX SDK version installed
#
# macOS 10.15.4 kernel compilation successfully tested on macOS 10.15.6 and Xcode 11.6
#
# MACOS_VERSION=10.15.4 BACKUP_SDK=1 OPTIONS=RELEASE,DEVELOPMENT ./build-xnu.sh
# XNU_VERSION=xnu-4570.41.2 ./build-xnu.sh

set_macos_version() {
    [[ $XNU_VERSION != "xnu-"* ]] && XNU_VERSION="${XNU_VERSION/#/xnu-}"
    echo "[+] Finding macOS version corresponding to XNU version ${XNU_VERSION}. May take a while..."
    for i in {11..14}; do
        for j in {0..6}; do
            (( j == 0 )) && j="${j//0/}"
            if (( i < 12 )); then
                curl -s --connect-timeout 4 "${APPLE_OPENSOURCE_RELEASE}os-x-10${i}${j}.html" | grep "$XNU_VERSION" >/dev/null
            else
                curl -s --connect-timeout 4 "${APPLE_OPENSOURCE_RELEASE}macos-10${i}${j}.html" | grep "$XNU_VERSION" >/dev/null
            fi
            (( $? == 0 )) && {
                (( j == 0 )) && MACOS_VERSION="10.${i}" || MACOS_VERSION="10.${i}.${j}";
                break 2;
            }
        done
    done
    if [[ ! $MACOS_VERSION ]]; then
        echo "[-] Couldn't find any macOS version related to ${XNU_VERSION}." >&2 && return 1
    else
        echo "[+] Found macOS ${MACOS_VERSION}" && return 0
    fi
}

APPLE_OPENSOURCE_RELEASE="https://opensource.apple.com/release/"
APPLE_OPENSOURCE_TARBALL="https://opensource.apple.com/tarballs/"
WORKSPACE_DIR="build"

# Ensure version is passed, and set MACOS_VERSION variable.
[[ ! $XNU_VERSION && ! $MACOS_VERSION ]] && { echo "[-] Expecting XNU_VERSION or MACOS_VERSION." >&2; exit 1; }
[[ $XNU_VERSION ]] && { set_macos_version || exit 1; }

# Check version is passed properly.
if grep -q '\.' <<< "${MACOS_VERSION}"; then
    IFS='.' read -a MACOS_VERSION <<< "${MACOS_VERSION}"
else
    echo "[-] Unrecognized version format." >&2 && exit 1
fi

if (( "${MACOS_VERSION[1]}" < 12 )); then
    APPLE_OPENSOURCE_RELEASE+="os-x"
    WORKSPACE_DIR+="-osx-10${MACOS_VERSION[1]}${MACOS_VERSION[2]}"
else
    APPLE_OPENSOURCE_RELEASE+="macos"
    WORKSPACE_DIR+="-macos-10${MACOS_VERSION[1]}${MACOS_VERSION[2]}"
fi

# Actual script.
set -ex

mkdir -p "${WORKSPACE_DIR}"
cd "${WORKSPACE_DIR}"
MACOS_VERSION_ID="${MACOS_VERSION[1]}"
MACOS_SDK_XNU="macosx10.${MACOS_VERSION_ID}"
TOOLCHAINPATH="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
SDKINFOPATH="$(xcode-select -p)/Platforms/MacOSX.platform/Info.plist"
MINIMUM_SDK_VERSION=$(defaults read "$(xcode-select -p)/Platforms/MacOSX.platform/Info.plist" "MinimumSDKVersion" | cut -d'.' -f2)

if (( MINIMUM_SDK_VERSION > MACOS_VERSION_ID )); then
    sudo plutil -replace MinimumSDKVersion -string "10.${MACOS_VERSION_ID}" "${SDKINFOPATH}"
fi

SDKPATH="$(xcrun --sdk ${MACOS_SDK_XNU} --show-sdk-path)"
KERNELPATH="BUILD/obj/OPTION_X86_64/kernel"
LIBSYSTEMPATH="BUILD.libsyscall/dst/usr/lib/system/libsystem_kernel.dylib"
IS_SIERRA_OR_HIGHER=$(( MACOS_VERSION_ID > 11 ))

[[ $BACKUP_SDK == 1 ]] && sudo ditto "${SDKPATH}" "${SDKPATH}.bak"

# Download XNU and all the needed dependencies.
sources=("xnu" "dtrace" "AvailabilityVersions")
[[ $IS_SIERRA_OR_HIGHER == 1 ]] && sources+=("libplatform" "libdispatch")
for i in "${!sources[@]}"; do
    tarball_name=$(curl -s "${APPLE_OPENSOURCE_RELEASE}-10${MACOS_VERSION_ID}${MACOS_VERSION[2]}.html" | grep "tarballs/${sources[$i]}" | sed -e 's/.*\/\(.*\)\".*/\1/')
    sources[$i]+="/${tarball_name}"
    curl "${APPLE_OPENSOURCE_TARBALL}${sources[$i]}" | tar -xz
done

# Build Dtrace.
cd dtrace-*
grep -rl "macosx.internal" . | while read i; do sed -i '' -e 's/macosx.internal/'"$MACOS_SDK_XNU"'/' "$i"; done
sed -i '' -e 's|llvm/Support/DataTypes\.h|DataTypes\.h|' ./include/llvm-Support/PointerLikeTypeTraits.h
curl -O https://raw.githubusercontent.com/llvm/llvm-project/master/llvm/include/llvm-c/DataTypes.h
cp ./DataTypes.h "${PWD}/include/llvm-Support/"
mkdir -p obj sym dst
xcodebuild install -target ctfconvert -target ctfdump -target ctfmerge ARCHS="x86_64" SRCROOT="${PWD}" OBJROOT="${PWD}/obj" SYMROOT="${PWD}/sym" DSTROOT="${PWD}/dst"
sudo ditto "${PWD}/$(find . -name 'XcodeDefault.xctoolchain')" "${TOOLCHAINPATH}"

# Build AvailabilityVersions.
cd ../AvailabilityVersions-*
mkdir -p dst
make install SRCROOT="${PWD}" DSTROOT="${PWD}/dst"
sudo ditto "${PWD}/dst/usr/local" "${SDKPATH}/usr/local"

cd ..
curl -O https://opensource.apple.com/source/CoreOSMakefiles/CoreOSMakefiles-77/Xcode/BSD.xcconfig
sed -i '' -e 's/macosx.internal/'"$MACOS_SDK_XNU"'/' BSD.xcconfig
cd xnu-*

# Got an error when compiling libkern/section_keywords.h in El Capitan > 2, so we replace the header with the only macro used.
if [[ $MACOS_VERSION_ID == 11 && "${MACOS_VERSION[2]-}" > 2 ]]; then
    sed -i '' -e 's/.*section_keywords.*/#define SECURITY_READ_ONLY_LATE(_t) _t/' ./bsd/kern/kern_cs.c
fi

# Introduction of cpu_shadow_sort() in osfmk/i386/cpu_topology.c on macOS 10.13.2 generates errors that impede proper building.
if [[ $MACOS_VERSION_ID == 13 && "${MACOS_VERSION[2]-}" > 1 ]]; then
    sed -i '' -e $'1,/^#include/ s/^#include/#include <stddef.h>\\\n&/' ./osfmk/i386/cpu_topology.c
fi

# In bsd/net/if_ipsec.c, ipsec_needs_netagent member of struct ipsec_pcb should be used only if IPSEC_NEXUS is set.
if [[ $MACOS_VERSION_ID == 13 && "${MACOS_VERSION[2]-}" > 4 ]]; then
    # First we join return type with name of ipsec_interface_needs_netagent() (multiline pattern may not be that easy to achieve with sed). Then we ifdef function.
    sed -i '' -e '/^boolean_t$/ N;s/\n/ /' \
              -e '/return (pcb->ipsec_needs_netagent == true);/ N;s/\n/ /' \
              -e $'s/boolean_t ipsec_interface_needs_netagent/#if IPSEC_NEXUS\\\n&/' \
              -e $'s|return (pcb->ipsec_needs_netagent == true); }|&\\\n#endif // IPSEC_NEXUS|' ./bsd/net/if_ipsec.c
fi

# Surround irrelevant code w/ #if 0 - #endif and add missing header/variable.
if [[ $MACOS_VERSION_ID == 15 ]]; then
    sed -i '' -e $'s/boolean_t intrs = ml_set_interrupts_enabled/#if 0\\\n&/' \
              -e $'/if (bitfield32(cap5reg, 13, 9) == 3) {/{N;N;s/.*return 1;\\n.*}/&\\\n#endif/;}' ./osfmk/i386/cpuid.h

    sed -i '' -e $'1,/^#include/ s/^#include/#include "pfvar.h"\\\n&/' ./bsd/net/if_bridge.c

    sed -i '' -e $'s/nfsnode_t np = VTONFS(vp);/&\\\n\\\tvfs_context_t ctx = ap->a_context;/' ./bsd/nfs/nfs_node.c
fi

if [[ $IS_SIERRA_OR_HIGHER == 1 ]]; then
    # Install XNU & libsyscall headers.
    unset PYTHONPATH
    mkdir -p BUILD.hdrs/obj BUILD.hdrs/sym BUILD.hdrs/dst
    make installhdrs SDKROOT="${MACOS_SDK_XNU}" ARCH_CONFIGS=X86_64 SRCROOT="${PWD}" OBJROOT="${PWD}/BUILD.hdrs/obj" SYMROOT="${PWD}/BUILD.hdrs/sym" DSTROOT="${PWD}/BUILD.hdrs/dst"
    touch libsyscall/os/thread_self_restrict.h
    sed -i '' -e 's|<DEVELOPER_DIR>/Makefiles/CoreOS/Xcode/||' ./libsyscall/Libsyscall.xcconfig
    cp ../BSD.xcconfig "${PWD}/libsyscall"
    xcodebuild installhdrs -project libsyscall/Libsyscall.xcodeproj -sdk "${MACOS_SDK_XNU}" ARCHS="x86_64" SRCROOT="${PWD}/libsyscall" OBJROOT="${PWD}/BUILD.hdrs/obj" SYMROOT="${PWD}/BUILD.hdrs/sym" DSTROOT="${PWD}/BUILD.hdrs/dst"
    sudo chown -R root:wheel BUILD.hdrs/dst/
    sudo ditto BUILD.hdrs/dst "${SDKPATH}"

    # Install libplatform headers.
    cd ../libplatform-*
    sudo ditto "${PWD}/include" "${SDKPATH}/usr/local/include"
    sudo ditto "${PWD}/private" "${SDKPATH}/usr/local/include"

    # Build libfirehose_kernel.a from the libdispatch library.
    cd ../libdispatch-*
    sed -i '' -e 's|<DEVELOPER_DIR>/Makefiles/CoreOS/Xcode/||' ./xcodeconfig/libdispatch.xcconfig
    sed -i '' -e '/AppleInternal\/XcodeConfig\/PlatformSupport\.xcconfig/d' ./xcodeconfig/libdispatch.xcconfig
    sed -i '' -e 's/macosx.internal/'"$MACOS_SDK_XNU"'/' ./xcodeconfig/libdispatch.xcconfig
    cp ../BSD.xcconfig "${PWD}/xcodeconfig"
    mkdir -p obj sym dst
    xcodebuild install -project libdispatch.xcodeproj -target libfirehose_kernel -sdk "${MACOS_SDK_XNU}" ARCHS="x86_64" SRCROOT="${PWD}" OBJROOT="${PWD}/obj" SYMROOT="${PWD}/sym" DSTROOT="${PWD}/dst"
    sudo ditto "${PWD}/dst/usr/local" "${SDKPATH}/usr/local"
    cd ../xnu-*
fi

# Turns out that, depending on the Xcode version used, some errors might occur when building non-recent stock kernels, so we sharply comment out all compiler's warning options.
sed -i '' -E '/((CXX)?WARNFLAGS_STD) /,/^[^[:blank:]].*\$/ s/^/#/' ./makedefs/MakeInc.def

if [[ ! $OPTIONS ]]; then
    OPTIONS="RELEASE"
else
    OPTIONS=$(tr ',' ' ' <<< "${OPTIONS}")
fi

# Build XNU.
make -j4 SDKROOT="${MACOS_SDK_XNU}" ARCH_CONFIGS=X86_64 KERNEL_CONFIGS="${OPTIONS}"

# Undo only the SDK change.
if (( MINIMUM_SDK_VERSION > MACOS_VERSION_ID )); then
    sudo plutil -replace MinimumSDKVersion -string "10.${MINIMUM_SDK_VERSION}" "${SDKINFOPATH}"
fi

for option in $OPTIONS; do
    case "$option" in
        RELEASE     )
            binary_path=$(sed -e 's/OPTION/RELEASE/' <<< "${KERNELPATH}")
            [[ -f $binary_path ]] && echo "[+] XNU kernel built at ${binary_path}.";;
        DEVELOPMENT )
            binary_path=$(sed -e 's/OPTION/DEVELOPMENT/;s/$/.development/' <<< "${KERNELPATH}")
            [[ -f $binary_path ]] && echo "[+] XNU kernel built at ${binary_path}.";;
        DEBUG       )
            binary_path=$(sed -e 's/OPTION/DEBUG/;s/$/.debug/' <<< "${KERNELPATH}")
            [[ -f $binary_path ]] && echo "[+] XNU kernel built at ${binary_path}.";;
    esac
done
