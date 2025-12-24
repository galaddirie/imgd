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

- game server workflow example

ADD ERROR HIGHLIGHTING TO EXPRESSION UI


ADD COOL NODES LIKE A DOCKER NODE OR A KUBERNETES NODE 


add publish button

add save button and indicator for unsaved changes - we will also have auto save  

add undo/redo functionality - unsaved changes remain in session local storage 


n8n import feature



we should only be able to access data from a nodes direct upstream nodes. 




state machine support for cross execution memory - ex a workflow that has a saga pattern that needs to persist state between executions.

How should we handle versioning node executors
Version like this Nodes.V1.HttpRequest
With some sort of label to identify it’s the latest (same with how we have auto discovery for nodes
Only 1 node with the same name can have this label so V1.HTTP AND V2.HTTP conflict and throw either a test or compile error


execution registry 

fix edit oeprations client side uuid


update execution worker docs 


comlex triggers to solve 

websocket trigger ( on websocket connection open), nodes to proccess websocket events  - ex a game server, the workflow keeps proccessing events until the websocket is closed

stream trigger also

we need to figure our how we modle this, is each event a workflow execution or only one execution for the entire stream, if so how do we model workflows? special workflow event "trigger" nodes, basically after the initial websocket connection open event, the workflow keeps proccessing events using the event declared nodes as the new trigger? maybe not, there should be an elegent solution to this

we may need an option to disable things that add overhead like telemetry, metrics, logging, etc. for these types of workflows


Optimization: compile the workflows so we dont need to evaluate templates at runtime - this will drop 3-4ms per expression evaluation. workflow versions will have the compiled templates stored in the database. drafts are compiled on evey run