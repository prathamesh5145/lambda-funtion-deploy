#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status.

echo "Pushing the Docker image to Amazon ECR..."
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$AWS_REPOSITORY:latest

echo "Creating/Updating Lambda function..."
aws lambda create-function \
  --function-name randmalay \
  --package-type Image \
  --code ImageUri=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$AWS_REPOSITORY:latest \
  --role arn:aws:iam::$AWS_ACCOUNT_ID:role/LambdaExecutionRole \
  --architectures x86_64 \
  --timeout 15 \
  --memory-size 128 \
  || aws lambda update-function-code \
  --function-name randmalay \
  --image-uri $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$AWS_REPOSITORY:latest

echo "Checking for existing API Gateway..."
API_ID=$(aws apigateway get-rest-apis --query "items[?name=='randmalay-api'].id" --output text --region $AWS_REGION)

if [ "$API_ID" == "None" ]; then
  echo "Creating API Gateway..."
  aws apigateway create-rest-api \
    --name randmalay-api \
    --description "API Gateway for randmalay Lambda function" \
    --region $AWS_REGION \
    --output json > api_gateway_output.json
  API_ID=$(jq -r '.id' api_gateway_output.json)
else
  echo "Using existing API Gateway with ID $API_ID"
fi

ROOT_ID=$(aws apigateway get-resources --rest-api-id $API_ID --region $AWS_REGION --output json | jq -r '.items[] | select(.path == "/") | .id')

echo "Creating/Updating API resource..."
RESOURCE_ID=$(aws apigateway get-resources --rest-api-id $API_ID --region $AWS_REGION --output json | jq -r '.items[] | select(.path == "/hello") | .id')

if [ -z "$RESOURCE_ID" ]; then
  aws apigateway create-resource \
    --rest-api-id $API_ID \
    --parent-id $ROOT_ID \
    --path-part hello \
    --region $AWS_REGION
else
  echo "Using existing API resource with ID $RESOURCE_ID"
fi

echo "Creating/Updating GET method..."
aws apigateway put-method \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method GET \
  --authorization-type NONE \
  --region $AWS_REGION

echo "Creating/Updating integration..."
aws apigateway put-integration \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/$(aws lambda get-function --function-name randmalay --query 'Configuration.FunctionArn' --output text)/invocations \
  --region $AWS_REGION

echo "Creating/Updating deployment..."
aws apigateway create-deployment \
  --rest-api-id $API_ID \
  --stage-name prod \
  --region $AWS_REGION

echo "Granting API Gateway permission to invoke Lambda..."
aws lambda add-permission \
  --function-name randmalay \
  --principal apigateway.amazonaws.com \
  --statement-id apigateway-prod \
  --action lambda:InvokeFunction \
  --source-arn arn:aws:apigateway:$AWS_REGION::/restapis/$API_ID/*/GET/hello \
  --region $AWS_REGION
