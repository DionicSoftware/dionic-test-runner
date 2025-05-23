#!/usr/bin/env bash

#
# Set and display project path
#

UNITY_PROJECT_PATH="$GITHUB_WORKSPACE/$PROJECT_PATH"
echo "Using project path \"$UNITY_PROJECT_PATH\"."

BUILD_PATH="build"
BUILD_NAME="StandaloneLinux64"
BUILD_FILE="$BUILD_NAME"
BUILD_PATH_FULL="$GITHUB_WORKSPACE/$BUILD_PATH" # TODO: pass the $BUILD_PATH from build job to here instead of its default value
CUSTOM_BUILD_PATH="$BUILD_PATH_FULL/$BUILD_FILE"
echo "Using build path \"$BUILD_PATH_FULL\"."


if [ ! -e "$BUILD_PATH_FULL" ]; then
  echo "Couldn't find build from the build job! Aborting...."
  exit 420
else 
  echo "Build dir permissions:"
  ls -l $BUILD_PATH_FULL
  echo "Change permissions"
  chown -R $(whoami):$(whoami) $BUILD_PATH_FULL
  ls -l $BUILD_PATH_FULL

  echo "Build contents:"
  find $CUSTOM_BUILD_PATH -type f -exec ls -l {} \;
fi


#
# Set and display the artifacts path
#

echo "Using artifacts path \"$ARTIFACTS_PATH\" to save test results."
FULL_ARTIFACTS_PATH=$GITHUB_WORKSPACE/$ARTIFACTS_PATH

#
# Set and display the coverage results path
#

echo "Using coverage results path \"$COVERAGE_RESULTS_PATH\" to save test coverage results."
FULL_COVERAGE_RESULTS_PATH=$GITHUB_WORKSPACE/$COVERAGE_RESULTS_PATH

#
# Display custom parameters
#

echo "Using custom parameters $CUSTOM_PARAMETERS."

# The following tests are 2019 mode (requires Unity 2019.2.11f1 or later)
# Reference: https://docs.unity3d.com/2019.3/Documentation/Manual/CommandLineArguments.html

#
# Display the unity version
#

echo "Using Unity version \"$UNITY_VERSION\" to test."

#
# Setup token for private package registry.
#

if [ -n "$PRIVATE_REGISTRY_TOKEN" ]; then
  echo "Private registry token detected, creating .upmconfig.toml"

  UPM_CONFIG_TOML_PATH="$HOME/.upmconfig.toml"
  echo "Creating toml at path: $UPM_CONFIG_TOML_PATH"

  touch $UPM_CONFIG_TOML_PATH

  cat > "$UPM_CONFIG_TOML_PATH" <<EOF
  [npmAuth."$SCOPED_REGISTRY_URL"]
  token = "$PRIVATE_REGISTRY_TOKEN"
  alwaysAuth = true
EOF
fi

#
# Create an empty project for testing if in package mode
#

if [ "$PACKAGE_MODE" = "true" ]; then
  echo "Running tests on a Unity package rather than a Unity project."

  if ! command -v jq &> /dev/null
  then
      echo "jq could not be found. This is required for package mode, and is likely the result of using a custom Docker image. Please use the default image or install jq to your custom image."
      exit 1
  fi

  echo ""
  echo "###########################"
  echo "#    Package Folder       #"
  echo "###########################"
  echo ""

  ls -la  "$UNITY_PROJECT_PATH"
  echo ""

  echo "Creating an empty Unity project to add the package $PACKAGE_NAME to."

  TEMP_PROJECT_PATH="./TempProject"

  unity-editor \
    -batchmode \
    -createProject "$TEMP_PROJECT_PATH" \
    -quit

  # use jq to add the package to the temp project through manually modifying Packages/manifest.json
  echo "Adding package to the temporary project's dependencies and testables..."
  echo ""

  PACKAGE_MANIFEST_PATH="$TEMP_PROJECT_PATH/Packages/manifest.json"
  if [ ! -f "$PACKAGE_MANIFEST_PATH" ]; then
      echo "Packages/mainfest.json was not created properly. This indicates a problem with the Action, not with your package. Logging directories and aborting..."

      echo ""
      echo "###########################"
      echo "#   Temp Project Folder   #"
      echo "###########################"
      echo ""

      ls -a "$TEMP_PROJECT_PATH"

      echo ""
      echo "################################"
      echo "# Temp Project Packages Folder #"
      echo "################################"
      echo ""

      ls -a "$TEMP_PROJECT_PATH/Packages"

      exit 1
  fi

  PACKAGE_MANIFEST_JSON=$(cat "$PACKAGE_MANIFEST_PATH")
  if [ -z "$SCOPED_REGISTRY_URL" ] || [ -z "$REGISTRY_SCOPES" ]; then
    echo "$PACKAGE_MANIFEST_JSON" | \
      jq \
      --arg packageName "$PACKAGE_NAME" \
      --arg projectPath "$UNITY_PROJECT_PATH" \
      '.dependencies += {"com.unity.testtools.codecoverage": "1.1.1"} | .dependencies += {"\($packageName)": "file:\($projectPath)"} | . += {testables: ["\($packageName)"]}' \
      > "$PACKAGE_MANIFEST_PATH"

  else

    echo "$PACKAGE_MANIFEST_JSON" | \
      jq \
      --arg packageName "$PACKAGE_NAME" \
      --arg projectPath "$UNITY_PROJECT_PATH" \
      --arg scopedRegistryUrl "$SCOPED_REGISTRY_URL" \
      --argjson registryScopes "$(echo "[\"$REGISTRY_SCOPES\"]" | sed 's/,/","/g')" \
      '.dependencies += {"com.unity.testtools.codecoverage": "1.1.1"} |
      .dependencies += {"\($packageName)": "file:\($projectPath)"} |
      . += {testables: ["\($packageName)"]} |
      . += {scopedRegistries: [{"name":"dependency", "url":"\($scopedRegistryUrl)", scopes: $registryScopes}] }' \
      > "$PACKAGE_MANIFEST_PATH"
  fi

  UNITY_PROJECT_PATH="$TEMP_PROJECT_PATH"


fi


#
# Overall info
#

echo ""
echo "###########################"
echo "#    Artifacts folder     #"
echo "###########################"
echo ""
echo "Creating \"$FULL_ARTIFACTS_PATH\" if it does not exist."
mkdir -p $FULL_ARTIFACTS_PATH

echo ""
echo "###########################"
echo "#    Project directory    #"
echo "###########################"
echo ""
ls -alh "$UNITY_PROJECT_PATH"

#
# Testing for each platform
#
for platform in ${TEST_PLATFORMS//;/ }; do
  echo ""
  echo "###########################"
  echo "#   Testing in $platform  #"
  echo "###########################"
  echo ""

  if [[ "$platform" == "customstandalone" ]]; then
    runTests="--run-tests --path-to-old-saves $UNITY_PROJECT_PATH/ExplorersTestSaves/"
  else
    runTests="-executeMethod TestModule.RunTestsByScript"
  fi

  

  if [[ "$platform" == "customstandalone" ]]; then
    # Code Coverage currently only supports code ran in the Editor and not in Standalone/Player.
    # https://docs.unity3d.com/Packages/com.unity.testtools.codecoverage@1.2/manual/TechnicalDetails.html#how-it-works

    

    xvfb-run -a -e /dev/stdout "$CUSTOM_BUILD_PATH/$BUILD_NAME" \
      -batchmode \
      -nographics \
      -logFile "$FULL_ARTIFACTS_PATH/$platform-player.log" \
      $runTests 
      #-testResults "$FULL_ARTIFACTS_PATH/$platform-results.xml" \
      

    # Catch exit code
    TEST_EXIT_CODE=$?

    if [[ $TEST_EXIT_CODE -eq 0 ]]; then
      if grep -q "ALL_TESTS_SUCCESSFUL" "$FULL_ARTIFACTS_PATH/$platform-player.log" && ! grep -q "TEST_FAILURE" "$FULL_ARTIFACTS_PATH/$platform-player.log"; then
          TEST_EXIT_CODE=0
      else
          TEST_EXIT_CODE=2
      fi
    fi

    

    # Print player log output
    cat "$FULL_ARTIFACTS_PATH/$platform-player.log"
  else
    echo "We don't support other platforms yet"
    TEST_EXIT_CODE=3
  fi

  # Display results
  if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo "Run succeeded, no failures occurred";
  elif [ $TEST_EXIT_CODE -eq 2 ]; then
    echo "Run succeeded, some tests failed";
  elif [ $TEST_EXIT_CODE -eq 3 ]; then
    echo "Run failure (other failure)";
  else
    echo "Unexpected exit code $TEST_EXIT_CODE";
  fi

  if [ $TEST_EXIT_CODE -ne 0 ]; then
    TEST_RUNNER_EXIT_CODE=$TEST_EXIT_CODE
  fi

  echo ""
  echo "###########################"
  echo "#    $platform Results    #"
  echo "###########################"
  echo ""

  if [[ "$platform" != "custom" ]]; then
    echo "We don't support .xml results yet!"
  elif [[ "$platform" != "COMBINE_RESULTS" ]]; then
    cat "$FULL_ARTIFACTS_PATH/$platform-results.xml"
    cat "$FULL_ARTIFACTS_PATH/$platform-results.xml" | grep test-run | grep Passed
  fi
done



#
# Permissions
#

# Make a given user owner of all artifacts
if [[ -n "$CHOWN_FILES_TO" ]]; then
  chown -R "$CHOWN_FILES_TO" "$UNITY_PROJECT_PATH"
  chown -R "$CHOWN_FILES_TO" "$FULL_ARTIFACTS_PATH"
  chown -R "$CHOWN_FILES_TO" "$FULL_COVERAGE_RESULTS_PATH"
fi

# Add read permissions for everyone to all artifacts
chmod -R a+r "$UNITY_PROJECT_PATH"
chmod -R a+r "$FULL_ARTIFACTS_PATH"

# Check if coverage results directory exists
if [ -d "$FULL_COVERAGE_RESULTS_PATH" ]; then
  chmod -R a+r "$FULL_COVERAGE_RESULTS_PATH"
else
  echo "Coverage results directory does not exist. If you are expecting coverage results, please make sure the Code Coverage package is installed in your unity project and that it is set up correctly."
fi
