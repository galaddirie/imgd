Credentials

API KEYs
sub workflows 


FUTURE
Kino like ui builder
datasets
Evaluations
ai chat workflow builder 
Light weight deployments and easy installs (should be able to run the entire system on a rasberry pi)

integrate wasm sandbox with OTEL metrics and telemetry


Create example workflows
- flame example take in video and return thumbnails ( we should have the example realtime ui here maybe via sdk for now), workflow output should a streaming endpoint

- multi node example for self hosted audience - get file from pc send it to laptop to run code 

ADD ERROR HIGHLIGHTING TO EXPRESSION UI


ADD COOL NODES LIKE A DOCKER NODE OR A KUBERNETES NODE 


add publish button

add save button and indicator for unsaved changes - we will also have auto save  

add undo/redo functionality - unsaved changes remain in session local storage 


n8n import feature


for some reason only some values of a node are configurable  while some fields automatically get assigned values from previous nodes. 

99.999% of nodes will  not automatically assigned values from previous nodes,  like in n8n, they will most likey use fixed values or use expressions to access data from previous nodes or upstream nodes.

connections are purely used to infer dependency / hierarchy between nodes. not to flow data from one node output to  a specific input of another node. ex our math node takes in a operation, value and an operand, the value is the input of the node and the operand is a fixed value. it should just take in two value inputs and that we can populate with either fixed values or expressions.


we should only be able to access data from a nodes direct upstream nodes. 


remove extras and metadata from execution struct, ugly 


state machine support for cross execution memory - ex a workflow that has a saga pattern that needs to persist state between executions.

How should we handle versioning node executors
Version like this Nodes.V1.HttpRequest
With some sort of label to identify it’s the latest (same with how we have auto discovery for nodes
Only 1 node with the same name can have this label so V1.HTTP AND V2.HTTP conflict and throw either a test or compile error