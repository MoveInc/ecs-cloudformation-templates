# Blue/Green Deployments using AWS ECS, Including Canary and Rollback Support

This article describes how Move performs blue/green deployments using
[Amazon’s Elastic Container Service (ECS)](https://aws.amazon.com/ecs/) without changing the
application’s DNS entry. Canary containers are used to slowly introduce a new application
version in production. The blue/green deployments allow us to fully rollback a bad deployment
in under a minute.

This is a follow up to the article [A Better ECS](https://techblog.realtor.com/a-better-ecs/) that
goes into detail about how our ECS clusters are configured at Move.

## Canary Deployments

The first part of our application deployment process in ECS is to introduce a single canary
container with the new application version and wire it into the existing ECS service. A separate
CloudFormation stack is created for this canary container and the container is registered with
the existing ALB target group so that a subset of the traffic will go to this canary container.

Unfortunately, the ALB at this time does not support sending a certain percentage of traffic to
different containers. In order to overcome this limitation, we introduce a new container which
will receive a percentage of traffic based on the total number of containers.  For instance, if
your application currently has 9 containers with the previous application version, and 1 canary
container with the new application version, then the canary will receive approximately 10% of
the traffic.

While the canary is running, we’d like to ensure that requests from clients which are accessing
the canary do not crossover to containers that are still running the prior application version.
In order to mitigate this, the ECS service in our CloudFormation template is setup with
stickiness turned on via the stickiness.enabled target group attribute on the
AWS::ElasticLoadBalancingV2::TargetGroup CloudFormation resource.

## Blue / Green Deployments

After the canary container has been live for some period of time (typically 5 minutes for most
applications), our deployment pipeline then proceeds with a full blue/green deployment.

At a high level, a DNS entry points to a single Application Load Balancer (ALB) and the DNS entry
does not change between deployments. For each application, there will be two services in ECS
called myapp-blue and myapp-green. Host based routing is used on the ALB to control how the
traffic is routed. A new deployment goes out to the inactive service, automated smoke tests are
performed against that deployment, and if successful, the host routes in the ALB are updated so
that the traffic is routed to the newly deployed service. If a rollback needs to occur, then the
host routes at the ALB can be updated without making any changes to the ECS services. Here is a
detailed walkthrough of this process:

### Initial State

ECS Service Name     | Version | Hostname                | ALB Priority | Remarks
---------------------|---------|-------------------------|--------------|--------
myapp-blue           | v1      | myapp.move.com          |          100 | myapp.move.com currently points here and is serving all traffic to end users.
myapp-green          | None    |                         |          200 | ECS service does not exist yet.

### Deploy v2 to green service

ECS Service Name     | Version | Hostname                | ALB Priority | Remarks
---------------------|---------|-------------------------|--------------|--------
myapp-blue           | v1      | myapp.move.com          |          100 | Customer traffic is served by this service.
myapp-green          | **v2**  | myapp-inactive.move.com |          200 | **v2 is deployed here. Automated smoke tests are performed against this service using the hostname myapp-inactive.move.com and the deployment will stop if any tests fail.**

### Update hostname of green service

ECS Service Name     | Version | Hostname                | ALB Priority | Remarks
---------------------|---------|-------------------------|--------------|--------
myapp-blue           | v1      | myapp.move.com          |          100 | Customer traffic is served by this service.
myapp-green          | v2      | **myapp.move.com**      |          200 | **Both ECS services now have the same hostname. The blue side will continue to receive all customer traffic since it has a lower ALB priority.**

### Mark blue ECS service as inactive

ECS Service Name     | Version | Hostname                    | ALB Priority | Remarks
---------------------|---------|-----------------------------|--------------|--------
myapp-blue           | v1      | **myapp-inactive.move.com** |          100 | **Service is now inactive.**
myapp-green          | v2      | myapp.move.com              |          200 | **All customer traffic is now routed to this service.**

Our Jenkins pipeline will keep the old application version around for a few hours and will then
automatically remove the ECS service for the previous application version if a rollback is not
requested during that time period.

| ![](images/ecs-blue-green-deployment.gif?raw=1) |
|:--:|
| *The blue/green deployment process.* |

Our Jenkins pipeline will keep the old application version around for a few hours and will
automatically remove the ECS service and associated resources for the previous application version
if a rollback is not requested during that time period.

## Rolling back a bad deployment

Rolling back a deployment simply requires swapping the hostnames for the two ECS services. After a
rollback occurs, the inactive service is still available with the inactive hostname and a developer
now has a low-stress environment in production to troubleshoot the error.

| ![](images/jenkins-ecs-rollback.jpg?raw=1) |
|:--:|
| *We have the ability to roll back to a previous application version wired into our Jenkins pipeline.* |

# CloudFormation templates

Our CloudFormation templates for ECS
[are available on GitHub](https://github.com/MoveInc/ecs-cloudformation-templates). The ECS service
template is available in the file
[ECS-Service.template](https://github.com/MoveInc/ecs-cloudformation-templates/ECS-Service.template)
and the canary support is in the file
[ECS-Service-Canary.template](https://github.com/MoveInc/ecs-cloudformation-templates/ECS-Service-Canary.template).
