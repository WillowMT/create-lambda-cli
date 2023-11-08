#!/bin/bash

# Check for required commands
if ! command -v aws &> /dev/null
then
    echo "aws CLI not found, please install and configure it."
    exit 1
fi

# Check input arguments
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <lambda_name> <region>"
    exit 1
fi

# Arguments
lambda_name=$1
region=$2

# Set default role ARN (replace with your Lambda execution role ARN)
default_role_arn="arn:aws:iam::608853446991:role/exec-role"

# Default code template for Node.js 18.x
cat > index.js << 'EOF'
exports.handler = async (event) => {
    const response = {
        statusCode: 200,
        body: JSON.stringify('Hello from Lambda via API Gateway!'),
    };
    return response;
};
EOF

# Zip the code
zip function.zip index.js

# Create the lambda function
create_function_output=$(aws lambda create-function \
    --function-name "$lambda_name" \
    --region "$region" \
    --zip-file fileb://function.zip \
    --handler index.handler \
    --runtime nodejs18.x \
    --role "$default_role_arn" \
    --output json)

lambda_arn=$(echo $create_function_output | jq -r .FunctionArn)

# Clean up the temporary files
rm index.js function.zip

# Create a new REST API
api_id=$(aws apigateway create-rest-api \
    --name "${lambda_name}_api" \
    --region "$region" \
    --endpoint-configuration types=REGIONAL \
    --output text \
    --query 'id')

# Get the root resource ID
root_id=$(aws apigateway get-resources \
    --rest-api-id "$api_id" \
    --region "$region" \
    --query 'items[?path==`/`].id' \
    --output text)

# Create a new resource under the root path
resource_id=$(aws apigateway create-resource \
    --rest-api-id "$api_id" \
    --region "$region" \
    --parent-id "$root_id" \
    --path-part "{proxy+}" \
    --query 'id' \
    --output text)

# Create a ANY method for the resource
aws apigateway put-method \
    --rest-api-id "$api_id" \
    --region "$region" \
    --resource-id "$resource_id" \
    --http-method ANY \
    --authorization-type NONE \
    --request-parameters "method.request.path.proxy=true"

# Set the Lambda function as the ANY method integration
aws apigateway put-integration \
    --rest-api-id "$api_id" \
    --region "$region" \
    --resource-id "$resource_id" \
    --http-method ANY \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:$region:lambda:path/2015-03-31/functions/$lambda_arn/invocations"

# Deploy the API to a new stage
deployment_id=$(aws apigateway create-deployment \
    --rest-api-id "$api_id" \
    --region "$region" \
    --stage-name prod \
    --query 'id' \
    --output text)

# Add permission for API Gateway to invoke the Lambda function
aws lambda add-permission \
    --function-name "$lambda_arn" \
    --statement-id apigateway-test-2 \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$region:608853446991:$api_id/*/ANY/{proxy+}" \
    --region "$region"

# Output the invocation URL
echo "Lambda function '$lambda_name' created in region '$region'"
echo "API Gateway endpoint URL:"
echo "https://$api_id.execute-api.$region.amazonaws.com/prod/{proxy}"
