#!/usr/bin/env bash

### Usage: ./prep.sh [options]
###
###   Prepares a tarball to be built by downloading Private.SourceBuilt.Artifacts.*.tar.gz and
###   installing the version of dotnet referenced in global.json
###
### Options:
###   --bootstrap                   Build a bootstrap version of previously source-built packages archive.
###                                 This modifies the downloaded version, replacing portable packages
###                                 with official ms-built packages restored from package feeds.
###   --no-artifacts                Exclude the download of the previously source-built artifacts archive
###   --no-prebuilts                Exclude the download of the prebuilts archive
###   --no-sdk                      Exclude the download of the .NET SDK
###   --smoke-test-prereqs-path     Directory where the smoke test prereqs packages should be downloaded to
###   --smoke-test-prereqs-feed     Additional NuGet package feed URL from which to download the smoke test
###                                 prereqs
###   --smoke-test-prereqs-feed-key Access token for the smoke test preqreqs NuGet package feed. If not
###                                 specified, an interactive restore will be used.

set -euo pipefail
IFS=$'\n\t'

source="${BASH_SOURCE[0]}"
SCRIPT_ROOT="$(cd -P "$( dirname "$0" )" && pwd)"

function print_help () {
    sed -n '/^### /,/^$/p' "$source" | cut -b 5-
}

buildBootstrap=false
downloadArtifacts=true
downloadPrebuilts=true
installDotnet=true
smokeTestPrereqsFeed=''
smokeTestPrereqsFeedKey=''
smokeTestPrereqsPath=''
positional_args=()
while :; do
    if [ $# -le 0 ]; then
        break
    fi
    lowerI="$(echo "$1" | awk '{print tolower($0)}')"
    case $lowerI in
        "-?"|-h|--help)
            print_help
            exit 0
            ;;
        --bootstrap)
            buildBootstrap=true
            ;;
        --no-artifacts)
            downloadArtifacts=false
            ;;
        --no-prebuilts)
            downloadPrebuilts=false
            ;;
        --no-sdk)
            installDotnet=false
            ;;
        --smoke-test-prereqs-feed)
            smokeTestPrereqsFeed=$2
            shift
            ;;
        --smoke-test-prereqs-feed-key)
            smokeTestPrereqsFeedKey=$2
            shift
            ;;
        --smoke-test-prereqs-path)
            smokeTestPrereqsPath=$2
            shift
            ;;
        *)
        positional_args+=("$1")
        ;;
    esac

    shift
done

DOTNET_SDK_PATH="$SCRIPT_ROOT/.dotnet"

# Attempting to bootstrap without an SDK will fail. So either the --no-sdk flag must be passed
# or a pre-existing .dotnet SDK directory must exist.
if [ "$buildBootstrap" == true ] && [ "$installDotnet" == false ] && [ ! -d $DOTNET_SDK_PATH ]; then
  echo "  ERROR: --no-sdk requires --no-bootstrap or a pre-existing .dotnet SDK directory.  Exiting..."
  exit 1
fi

# Downloading smoke test prereq packages requires a .NET installation
if [ -n "$smokeTestPrereqsPath" ] && [ "$installDotnet" == false ] && [ ! -d $DOTNET_SDK_PATH ]; then
  echo "  ERROR: --smoke-test-prereqs-path requires --no-sdk to be unset or a pre-existing .dotnet SDK directory.  Exiting..."
  exit 1
fi

# If the smoke test prereqs feed key is set, then smoke test prereqs feed must also be set
if [ -n "$smokeTestPrereqsFeedKey" ] && [ -z "$smokeTestPrereqsFeed" ]; then
  echo "  ERROR: --smoke-test-prereqs-feed must be set if --smoke-test-prereqs-feed-key is set.  Exiting..."
  exit 1
fi

# Check for the archive text file which describes the location of the archive files to download
if [ ! -f $SCRIPT_ROOT/packages/archive/archiveArtifacts.txt ]; then
    echo "  ERROR: $SCRIPT_ROOT/packages/archive/archiveArtifacts.txt does not exist.  Cannot determine which archives to download.  Exiting..."
    exit -1
fi

# Check to make sure curl exists to download the archive files
if ! command -v curl &> /dev/null
then
    echo "  ERROR: curl not found.  Exiting..."
    exit -1
fi

# Check if Private.SourceBuilt artifacts archive exists
if [ "$downloadArtifacts" == true ] && [ -f $SCRIPT_ROOT/packages/archive/Private.SourceBuilt.Artifacts.*.tar.gz ]; then
    echo "  Private.SourceBuilt.Artifacts.*.tar.gz exists...it will not be downloaded"
    downloadArtifacts=false
fi

# Check if Private.SourceBuilt prebuilts archive exists
if [ "$downloadPrebuilts" == true ] && [ -f $SCRIPT_ROOT/packages/archive/Private.SourceBuilt.Prebuilts.*.tar.gz ]; then
    echo "  Private.SourceBuilt.Prebuilts.*.tar.gz exists...it will not be downloaded"
    downloadPrebuilts=false
fi

# Check if dotnet is installed
if [ "$installDotnet" == true ] && [ -d $SCRIPT_ROOT/.dotnet ]; then
    echo "  ./.dotnet SDK directory exists...it will not be installed"
    installDotnet=false;
fi

# Read the archive text file to get the archives to download and download them
while read -r line; do
    if [[ $line == *"Private.SourceBuilt.Artifacts"* ]]; then
        if [ "$downloadArtifacts" == "true" ]; then
            echo "  Downloading source-built artifacts from $line..."
            (cd $SCRIPT_ROOT/packages/archive/ && curl --retry 5 -O $line)
        fi
    fi
    if [[ $line == *"Private.SourceBuilt.Prebuilts"* ]]; then
        if [ "$downloadPrebuilts" == "true" ]; then
            echo "  Downloading source-built prebuilts from $line..."
            (cd $SCRIPT_ROOT/packages/archive/ && curl --retry 5 -O $line)
        fi
    fi
done < $SCRIPT_ROOT/packages/archive/archiveArtifacts.txt

# Check for the version of dotnet to install
if [ "$installDotnet" == "true" ]; then
    echo "  Installing dotnet..."
    (source ./eng/common/tools.sh && InitializeDotNetCli true)
fi

# Build bootstrap, if specified
if [ "$buildBootstrap" == "true" ]; then
    # Create working directory for running bootstrap project
    workingDir=$(mktemp -d)
    echo "  Building bootstrap previously source-built in $workingDir"

    # Copy bootstrap project to working dir
    cp $SCRIPT_ROOT/eng/bootstrap/buildBootstrapPreviouslySB.csproj $workingDir

    # Copy NuGet.config from the installer repo to have the right feeds
    cp $SCRIPT_ROOT/src/installer/NuGet.config $workingDir

    # Get PackageVersions.props from existing prev-sb archive
    echo "  Retrieving PackageVersions.props from existing archive"
    sourceBuiltArchive=`find $SCRIPT_ROOT/packages/archive -maxdepth 1 -name 'Private.SourceBuilt.Artifacts*.tar.gz'`
    if [ -f "$sourceBuiltArchive" ]; then
        tar -xzf "$sourceBuiltArchive" -C $workingDir PackageVersions.props
    fi

    # Run restore on project to initiate download of bootstrap packages
    $DOTNET_SDK_PATH/dotnet restore $workingDir/buildBootstrapPreviouslySB.csproj /bl:artifacts/prep/bootstrap.binlog /fileLoggerParameters:LogFile=artifacts/prep/bootstrap.log /p:ArchiveDir="$SCRIPT_ROOT/packages/archive/" /p:BootstrapOverrideVersionsProps="$SCRIPT_ROOT/eng/bootstrap/OverrideBootstrapVersions.props"

    # Remove working directory
    rm -rf $workingDir
fi

if [ -n "$smokeTestPrereqsPath" ] ; then
  smokeTestPrereqsProjPath="test/Microsoft.DotNet.SourceBuild.SmokeTests/assets"
  smokeTestPrereqsTmp="/tmp/smoke-test-prereqs"
  smokeTestsNuGetConfigPath="$smokeTestPrereqsTmp/nuget.config"
  smokeTestsFeedName="smoke-test-prereqs"

  # Generate a nuget.config file. If a feed was provided, include that first. Also include nuget.org feed by default.

  mkdir -p $smokeTestPrereqsTmp

  echo "<?xml version=\"1.0\" encoding=\"utf-8\"?>
<configuration>
  <packageSources>
    <clear />" > "$smokeTestsNuGetConfigPath"

  if [ -n "$smokeTestPrereqsFeed" ] ; then
    echo "<add key=\"$smokeTestsFeedName\" value=\"%SMOKE_TEST_PREREQS_FEED%\" />" >> "$smokeTestsNuGetConfigPath"
  fi

  echo "<add key=\"nuget\" value=\"https://api.nuget.org/v3/index.json\" />
  </packageSources>" >> "$smokeTestsNuGetConfigPath"

  # If the caller specified a PAT for accessing the feed, generate a credentials section
  if [ -n "$smokeTestPrereqsFeedKey" ] ; then
    echo "<packageSourceCredentials>
        <$smokeTestsFeedName>
        <add key=\"Username\" value=\"smoke-test-prereqs\" />
        <add key=\"ClearTextPassword\" value=\"%SMOKE_TEST_PREREQS_FEED_KEY%\" />
        </$smokeTestsFeedName>
    </packageSourceCredentials>" >> "$smokeTestsNuGetConfigPath"
  fi

  echo "</configuration>" >> "$smokeTestsNuGetConfigPath"
  
  # Gather the versions of various components so they can be passed as MSBuild properties

  function getPackageVersion() {
    # Extract the package version from the props XML file and trim the servicing label suffix if it exists
    sed -n 's:.*<OutputPackageVersion>\(.*\)</OutputPackageVersion>.*:\1:p' $1 | sed 's/-servicing.*//'
  }

  runtimeVersion=$(getPackageVersion git-info/runtime.props)
  aspnetCoreVersion=$(getPackageVersion git-info/aspnetcore.props)
  fsharpVersion=$(getPackageVersion git-info/fsharp.props)

  SMOKE_TEST_PREREQS_FEED=$smokeTestPrereqsFeed \
  SMOKE_TEST_PREREQS_FEED_KEY=$smokeTestPrereqsFeedKey \
  "$DOTNET_SDK_PATH/dotnet" msbuild \
    "$smokeTestPrereqsProjPath/prereqs.csproj" \
    /t:DownloadPrereqs \
    /bl:artifacts/prep/smokeTestPrereqs.binlog \
    /fileLoggerParameters:LogFile=artifacts/prep/smokeTestPrereqs.log \
    /p:RestorePackagesPath="$smokeTestPrereqsPath" \
    /p:RuntimeVersion=$runtimeVersion \
    /p:AspnetCoreVersion=$aspnetCoreVersion \
    /p:FsharpVersion=$fsharpVersion \
    /p:RestoreConfigFile=$smokeTestsNuGetConfigPath

fi
