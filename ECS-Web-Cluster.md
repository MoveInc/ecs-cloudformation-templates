# A better ECS

As more application services migrate to the AWS cloud, a pattern quickly emerges in which EC2
resources are considerably underutilized. While a wide array of EC2 instance types and autoscaling
options help to match the consumed infrastructure with current demand, many services still make
little use of the available memory, CPU, or bandwidth. In order to make better use of available
resources, AWS provides Elastic Container Service (ECS), which enables multiple services to run
on a single set of EC2 instances.

Developers moving onto ECS will most likely encounter difficulties getting the instance
autoscaling to operate as expected. This article describes how we were able to improve the
instance autoscaling, save money by running our Dev and QA EC2 instances on spot instances,
several other management improvements and best practices to manage the cluster.


## Instance autoscaling that works

Anyone that has ran multiple applications inside a single ECS cluster has most likely
encountered this error:

    service XXX was unable to place a task because no container instance met all of its
    requirements

The desired instance count of the EC2 autoscaling group would be below the maximum instance
count but the ECS scheduler is not aware of this. ECS provides CloudWatch metrics about the
overall CPU and memory reservation inside the cluster, however ECS currently does not
provide metrics about the number of pending tasks. Setting the scale up and scale down policy
based on multiple CloudWatch metrics can be problematic since there can be conflicts if one
metric says to scale up but the other metric says to scale down.

The method described at http://garbe.io/blog/2017/04/12/a-better-solution-to-ecs-autoscaling/
provides a solution to this problem. That blog post provides a Lambda function that publishes
a custom CloudWatch metric called SchedulableContainers. The Lambda function needs to know
the largest CPU and memory reservation that can be requested inside your cluster so that it can
calculate how many of the largest containers can be started. The instance autoscaling is
configured to only use this metric. In essence, this means that the cluster will always have
available capacity for one additional instance of the largest task.

For large applications, the ECS instance and service autoscaling had to be tightly coupled in
the past. We were initially getting around some of the ECS autoscaling issues by running our
ECS clusters a little larger than they needed to be. We are now able to run some of our ECS
clusters at 80-90% reservation capacity with no issues.

The Lambda function is included inline in the CloudFormation template.

| ![](images/ecs-cluster-as-desired-capacity.png?raw=1) |
|:--:|
| *An ECS service was started with 500 idle containers. The number of EC2 instances in the cluster automatically scaled up from 2 to 8 to handle running that many containers. Once everything was stable, the ECS service was manually removed from the cluster and the number of instances automatically scaled back down to 2. The cluster can be configured to scale up more aggressively if needed.* |

| ![](images/ecs-cluster-cloudwatch-schedulable-containers.png?raw=1) |
|:--:|
| *The SchedulableContainers CloudWatch metric that corresponds to the instance autoscaling graph from above. Notice that the number of SchedulableContainers goes up to 53 once the ECS service with 500 containers was removed and that is what triggers the instance autoscaling to slowly remove instances.* |


## Scaling down the cluster without affecting end users

When an ECS cluster scales down, your applications will likely see intermittent 50X errors
from the ALB when an instance is taken out of service. This is caused by AWS AutoScaling
not being aware of the ECS containers running on the instance that is terminated, so the
instance is shutting down while it is currently serving traffic. Ideally, the instance
should stop receiving traffic prior to shutting down.

AWS AutoScaling supports
[lifecycle hooks](https://docs.aws.amazon.com/autoscaling/ec2/userguide/lifecycle-hooks.html)
to notify a Lambda function when an instance is about to be terminated. AWS Support recommends
the Lambda function at
https://aws.amazon.com/blogs/compute/how-to-automate-container-instance-draining-in-amazon-ecs/
to gracefully drain the ECS tasks before the instance is terminated. The version provided
by AWS has several issues and a rewritten version is provided inline in the ECS cluster template
with the following changes:

- The AWS code can post messages to the wrong SNS topic when retrying. It looks for the first
  SNS topic in the account that has a lambda function subscribed to it and posts the retry message
  to that topic.
- The AWS code does not do any kind of pagination against the ECS API when reading the list of
  EC2 instances. So if it couldn't find the instance ID that was about to be terminated on the
  first page, then the instance was not set to DRAINING and the end users would see 50X
  messages when the operation timed out and autoscaling killed the instance.
- The retry logic did not put in any kind of delay in place when retrying. The Lambda function
  would be invoked about 5-10 times a second, and each Lambda function invocation would probably
  make close to a dozen AWS API calls. A 5 second delay between each retry was introduced.
- There was a large amount of unused code and variables in the in the AWS implementation.
- Converted the code from Python 2 to 3.
- Previously, the old Lambda function was included as a separate 8.1 MB ZIP file that needed
  to be stored at S3 and managed separately from the rest of your ECS cluster. Python code
  in AWS Lambda no longer needs to bundle all of its dependencies . With all of the refactoring
  above, the new Python code is small enough that it is embedded directly in the CloudFormation
  template to reduce external dependencies. This will make it easy to make changes to this code
  on a branch and test it against a single ECS cluster.

Other container schedulers, such as Kubernetes, will have the same issue and the same approach
can be used to drain pods.

| ![](images/ecs-cluster-instance-draining.png?raw=1) |
|:--:|
| *The cluster has an improved autodraining Lambda that integrates with AWS AutoScaling to drain containers during scale-down events which will avoid any unexpected 50X errors returned to the end users.* |


## Spot instances in Dev and QA environments

EC2 supports spot instances that allow you to bid on excess computing capacity that is available at
AWS. This typically saves between 70-90% off of the posted on-demand price. However, AWS can
terminate the spot instances at any time with only a two-minute termination notice given.

To reduce our AWS costs, we run our Dev and QA environments on spot instances when the spot bid
price is low. Since the bid price may be too high for several hours or more, we needed a way to fall
back to using on-demand instances when the bid price is too high. The
[Autospotting](https://github.com/cristim/autospotting) Lambda will automatically replace the
expensive on-demand instances with spot instances of equal size or larger when the bid price is low.
If one or more spot instances are terminated (such as due to a high bid price), then EC2
AutoScaling will start new on-demand instance(s). These on-demand instances will eventually be
replaced with spot instances once the bid price goes back down. Autospotting also tries to use a
diverse set of instance types to avoid issues all of the spot instances suddenly going away.

A script listens on each EC2 instance for the two-minute
[spot instance termination notification](https://aws.amazon.com/blogs/aws/new-ec2-spot-instance-termination-notices/)
from the EC2 metadata service. When an instance is scheduled to be terminated, the container
instance state is automatically set to DRAINING so that the existing containers can gracefully
drain.

We have plans to run a small subset of our production webservers on spot instances with the
help of Autospotting after more testing is completed.

| ![](images/ecs-cluster-spot-instances.png?raw=1) |
|:--:|
| *The instances inside this ECS cluster are currently running on spot instances inside our QA environment with the help of the Autospotting Lambda. The cluster is currently configured to use r4.xlarge on-demand instances and autospotting will give a diversified set of spot instance types of similar size to avoid any issues with all of the instances going away when the bid price suddenly increases. When an instance is terminated, a new on-demand instance is automatically started by AWS AutoScaling.* |


## cfn-init and forcing new EC2 instances

You can use [AWS::CloudFormation::Init](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-init.html)
to manage resources on the underlying EC2 instances. However, sometimes there are situations where
a file is changed, and services may need to be restarted. For instance, maybe a service is no
longer needed. Now you need to test the create and update code paths, which adds more administrative
overhead. In keeping with the "*cattle, not pets*" philosophy of infrastructure, we put a version
number in the autoscaling launch configuration user data script, and increment that number to
force new EC2 instances.

    ECSLaunchConfiguration:
      Type: AWS::AutoScaling::LaunchConfiguration
      Properties:
        UserData:
          "Fn::Base64": !Sub |
            #!/bin/bash
            # Increment version number below to force new instances in the cluster.
            # Version: 1

With this change, we now only need to test the code path that creates new EC2 instances.


## Logging drivers

The ECS logging driver is configured so that the
[Splunk](https://www.splunk.com/blog/2016/07/13/docker-amazon-ecs-splunk-how-they-now-all-seamlessly-work-together.html),
[CloudWatch logs](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/using_cloudwatch_logs.html), and
json-file log drivers are available to containers. It is up to each application's container
definition(s) to configure the appropriate logging driver. For example, the Splunk logging
driver can be configured on the
[ECS task definition](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ecs-taskdefinition.html)
like so:

    TaskDefinition:
      Type: AWS::ECS::TaskDefinition
      Properties:
        ContainerDefinitions:
          - Name: my-app-container
            LogConfiguration:
              LogDriver: splunk
              Options:
                splunk-token: my-apps-token
                splunk-url: https://splunk-url.local
                splunk-source: docker
                splunk-sourcetype: my-apps-env-name
                splunk-format: json
                splunk-verify-connection: false


## IAM roles

[Task-based IAM roles](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html)
are implemented so that the cluster doesn't need to run with the permissions of all applications
running inside it.

The ECS cluster itself needs some IAM roles configured for its proper operation and the provided
CloudFormation template uses the AWS-managed IAM roles when available so that the clusters
automatically get the required IAM permissions as new AWS features are made available in the
future.

    ECSRole:
      Type: AWS::IAM::Role
      Properties:
        ManagedPolicyArns:
          - arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role


## CloudFormation exports

After your ECS cluster is setup, you will need to know some duplicate information such as VPC
IDs, load balancer information, etc when setting up your ECS services. We use
[CloudFormation exports](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-exports.html)
so that the service can look up all of this information from the ECS cluster CloudFormation
stack. When setting up a new ECS service via CloudFormation, we only need to know 1) the AWS
region, 2) the CloudFormation stack name that has our ECS cluster, and 3) which shared load
balancer to attach to (internet-facing or internal). The ECS service can lookup the VPC
that the cluster is in with the CloudFormation snippet
`'Fn::ImportValue': "cluster-stack-name-VPC"`. This reduces the number of parameters that
our ECS services need to have.

| ![](images/ecs-cluster-cloudformation-exports.png?raw=1) |
|:--:|
| *The `Fn::ImportValue` function can be used from other CloudFormation stacks to import these values*. |


## Tagging compliance

All taggable AWS resources at Move must have the `owner`, `product`, `component`, and
`environment` tags present. We use the equivalent of `aws cloudformation create-stack --tags ...`
to provision our CloudFormation stacks so that all taggable AWS resources will get the proper
tags. There are two exceptions in the ECS cluster template:

- The EC2 AutoScaling group will get the tags, however `PropagateAtLaunch: true` will not be set
  so the EC2 instances that are started will not get the proper tags. These four tags are
  explicitly configured on the AutoScaling group so that the EC2 instances are tagged properly.
- The EBS volumes associated with the EC2 instances do not inherit the tags of the EC2 instance.
  On startup, each EC2 instance takes care of adding the appropriate tags to its EBS volumes.


## Application Load Balancers (ALBs)

The ECS cluster template allows you to create an internet-facing and an internal load balancer
to allow easily running multiple applications inside the same cluster. One or both of the load
balancers can be disabled via CloudFormation parameters if desired. Be aware that the ALB
[currently has a limit of 100 listener rules per load balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-limits.html).

A dedicated S3 bucket is created for the cluster to store the ALB access logs.


## Start a task on each ECS instance

ECS currently does not have the ability to start a task on each instance inside the cluster.
To work around this, each EC2 instance has the ability to start a task that will run only
on the current instance.


## CloudFormation Template

By following these best practices and techniques, ECS can significantly lower infrastructure
costs and simplify scaling, deployment, and management concerns. A fully functional CloudFormation
template which implements all of these best practices can be
[downloaded here](ECS-Web-Cluster.template).

The next article in this series will describe how we are doing blue/green deployments with canary
containers inside ECS.
