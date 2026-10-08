import json
import boto3
import os
from botocore.exceptions import ClientError

dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('DYNAMODB_TABLE', 'visitor-counter')
COUNTER_ID = os.environ.get('COUNTER_ID', 'main')


def cors_headers():
    return {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
    }


def lambda_handler(event, context):
    http_method = event.get('httpMethod', '')
    path = event.get('path', '')

    if http_method == 'OPTIONS':
        return {
            'statusCode': 200,
            'headers': cors_headers(),
            'body': '',
        }

    try:
        if path.endswith('/visits') or path == '/':
            if http_method == 'GET':
                return get_visits()
            elif http_method == 'POST':
                return increment_visits()
            else:
                return method_not_allowed()
        elif path.endswith('/visits/reset') and http_method == 'POST':
            return reset_visits()
        else:
            return not_found()
    except ClientError as e:
        return {
            'statusCode': 500,
            'headers': cors_headers(),
            'body': json.dumps({
                'error': 'DynamoDB error',
                'details': str(e)
            }),
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'headers': cors_headers(),
            'body': json.dumps({
                'error': 'Internal server error',
                'details': str(e)
            }),
        }


def get_visits():
    table = dynamodb.Table(TABLE_NAME)
    response = table.get_item(Key={'id': COUNTER_ID})
    item = response.get('Item')
    visits = item['visits'] if item else 0
    return {
        'statusCode': 200,
        'headers': cors_headers(),
        'body': json.dumps({'visits': visits}),
    }


def increment_visits():
    table = dynamodb.Table(TABLE_NAME)
    response = table.update_item(
        Key={'id': COUNTER_ID},
        UpdateExpression='SET visits = if_not_exists(visits, :start) + :inc',
        ExpressionAttributeValues={
            ':start': 0,
            ':inc': 1,
        },
        ReturnValues='UPDATED_NEW',
    )
    visits = int(response['Attributes']['visits'])
    return {
        'statusCode': 200,
        'headers': cors_headers(),
        'body': json.dumps({'visits': visits}),
    }


def reset_visits():
    table = dynamodb.Table(TABLE_NAME)
    table.put_item(Item={'id': COUNTER_ID, 'visits': 0})
    return {
        'statusCode': 200,
        'headers': cors_headers(),
        'body': json.dumps({'visits': 0, 'message': 'Counter reset successfully'}),
    }


def method_not_allowed():
    return {
        'statusCode': 405,
        'headers': cors_headers(),
        'body': json.dumps({'error': 'Method Not Allowed'}),
    }


def not_found():
    return {
        'statusCode': 404,
        'headers': cors_headers(),
        'body': json.dumps({'error': 'Not Found'}),
    }
