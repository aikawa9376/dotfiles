#!/bin/sh

# Customize the following:
# containerName="app"
# phpunitPath="./vendor/bin/phpunit"
# Customize the following:
containerName=$CONTAINER
phpunitPath=$REMOTE_PHPUNIT_BIN

# detect local path and remove from args
argsInput=${@}
runFile=$(echo $argsInput| awk '{print $1}')
phpTestPath=$(dirname "$runFile")
pushd $phpTestPath > /dev/null
projectPath="$(git rev-parse --show-toplevel)"
pushd > /dev/null

## detect test result output
for i in $argsInput; do
   case $i in
       --log-junit=*)
           outputPath="${i#*=}"
           ;;
       *)
           ;;
   esac
done

# replace with local
args=("${argsInput/$projectPath\//}")

# replace strange line with (data set .*)
args=("${args//(*}")

# Detect path
container=$(docker ps --filter id=$(docker inspect --format '{{.Id}}' $containerName) --format "{{.ID}}")
dockerPath=$(docker inspect --format {{.Config.WorkingDir}} $container)

## debug
# echo "Params: "${args[@]}
# echo "Docker: "$dockerPath
# echo "Local:  "$projectPath
# echo "Result: "$outputPath

# Run the tests
docker exec -i $container php -d memory_limit=-1 $phpunitPath ${args[@]}

# copy results
docker cp -a "$container:$outputPath" "$outputPath"|- &> /dev/null

# replace docker path to locals
sed -i "s#$dockerPath#$projectPath#g" $outputPath
