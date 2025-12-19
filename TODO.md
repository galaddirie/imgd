Code style checks

Credentials
global variables

API KEYs
sub workflows 

workflow marketplace


FUTURE
Kino like ui builder
datasets
Evaluations
ai chat workflow builder 
Light weight deployments and easy installs (should be able to run the entire system on a rasberry pi )


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

our workflows should not be port based, connections are purely used to infer dependency / hierarchy between nodes. not to flow data from one node output to  a specific input of another node.



# security updates
- scope workflow drafts= theey should be protected( non-owners should never be able to draft workflows, pinned outputs, etc. currently we preload the workflow for executions and workflow versions model)


we need consistent return types for nodes 

ex

{
  "results": [
    {
      "value": 1 # input node
    },
    11, # non-pinned node
    {
      "value": 122 # pinned node
    },
    {
      "value": 30 # pinned node
    }
  ]
}


todo model dev mode and pinned nodes better

we need to improve execution state store dependency injection, we call it directly sometimes

remove extras and metadata from execution struct, ugly 