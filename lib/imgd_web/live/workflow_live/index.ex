# defmodule ImgdWeb.WorkflowLive.Index do
#   @moduledoc """
#   LiveView for browsing workflows.

#   Presents an index of workflows with ability to create new ones.
#   """
#   use ImgdWeb, :live_view

#   alias Imgd.Workflows
#   alias Imgd.Workflows.Workflow
#   import ImgdWeb.Formatters, except: [trigger_label: 1]

#   @impl true
#   def mount(_params, _session, socket) do
#     scope = socket.assigns.current_scope

#     workflows =
#       scope
#       |> Workflows.list_workflows()
#       |> sort_workflows()

#     socket =
#       socket
#       |> assign(:page_title, "Workflows")
#       |> assign(:workflows_empty?, workflows == [])
#       |> assign(:show_create_modal, false)
#       |> assign(:form, nil)
#       |> stream(:workflows, workflows, dom_id: &"workflow-#{&1.id}")

#     {:ok, socket}
#   end

#   @impl true
#   def handle_event("open_create_modal", _params, socket) do
#     changeset = Workflows.change_workflow(%Workflow{}, %{})

#     socket =
#       socket
#       |> assign(:show_create_modal, true)
#       |> assign(:form, to_form(changeset))

#     {:noreply, socket}
#   end

#   @impl true
#   def handle_event("close_create_modal", _params, socket) do
#     socket =
#       socket
#       |> assign(:show_create_modal, false)
#       |> assign(:form, nil)

#     {:noreply, socket}
#   end

#   @impl true
#   def handle_event("validate_workflow", %{"workflow" => workflow_params}, socket) do
#     changeset =
#       %Workflow{}
#       |> Workflows.change_workflow(workflow_params)
#       |> Map.put(:action, :validate)

#     {:noreply, assign(socket, form: to_form(changeset))}
#   end

#   @impl true
#   def handle_event("create_workflow", %{"workflow" => workflow_params}, socket) do
#     scope = socket.assigns.current_scope

#     case Workflows.create_workflow(scope, workflow_params) do
#       {:ok, workflow} ->
#         socket =
#           socket
#           |> put_flash(:info, "Workflow created successfully")
#           |> assign(:show_create_modal, false)
#           |> assign(:form, nil)
#           |> stream_insert(:workflows, workflow, at: 0)
#           |> assign(:workflows_empty?, false)

#         {:noreply, socket}

#       {:error, %Ecto.Changeset{} = changeset} ->
#         {:noreply, assign(socket, form: to_form(changeset))}
#     end
#   end

#   @impl true
#   def handle_event("open_workflow", %{"workflow_id" => workflow_id}, socket) do
#     {:noreply, push_navigate(socket, to: ~p"/workflows/#{workflow_id}")}
#   end

#   @impl true
#   def handle_event("duplicate_workflow", %{"workflow_id" => workflow_id}, socket) do
#     scope = socket.assigns.current_scope

#     case Workflows.get_workflow(scope, workflow_id) do
#       nil ->
#         {:noreply, put_flash(socket, :error, "Workflow not found")}

#       workflow ->
#         case Workflows.duplicate_workflow(scope, workflow) do
#           {:ok, duplicated_workflow} ->
#             socket =
#               socket
#               |> put_flash(:info, "Workflow duplicated successfully")
#               |> stream_insert(:workflows, duplicated_workflow, at: 0)

#             {:noreply, socket}

#           {:error, _changeset} ->
#             {:noreply, put_flash(socket, :error, "Failed to duplicate workflow")}
#         end
#     end
#   end

#   @impl true
#   def handle_event("archive_workflow", %{"workflow_id" => workflow_id}, socket) do
#     scope = socket.assigns.current_scope

#     case Workflows.get_workflow(scope, workflow_id) do
#       nil ->
#         {:noreply, put_flash(socket, :error, "Workflow not found")}

#       workflow ->
#         case Workflows.archive_workflow(scope, workflow) do
#           {:ok, archived_workflow} ->
#             socket =
#               socket
#               |> put_flash(:info, "Workflow archived successfully")
#               |> stream_insert(:workflows, archived_workflow)

#             {:noreply, socket}

#           {:error, _changeset} ->
#             {:noreply, put_flash(socket, :error, "Failed to archive workflow")}
#         end
#     end
#   end

#   @impl true
#   def render(assigns) do
#     ~H"""
#     <Layouts.app flash={@flash} current_scope={@current_scope}>
#       <:page_header>
#         <div class="w-full space-y-6">
#           <div class="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
#             <div class="space-y-3">
#               <p class="text-xs font-semibold uppercase tracking-[0.3em] text-muted">Automation</p>
#               <div class="flex flex-wrap items-center gap-3">
#                 <h1 class="text-3xl font-semibold tracking-tight text-base-content">Workflows</h1>
#               </div>
#               <p class="max-w-2xl text-sm text-muted">
#                 Design, publish, and monitor the automations.
#                 Drafts stay private until you publish them.
#               </p>
#             </div>

#             <div class="flex gap-3">
#               <button
#                 type="button"
#                 phx-click="open_create_modal"
#                 class="btn btn-sm btn-primary gap-2 "
#               >
#                 <.icon name="hero-plus" class="size-5" />
#                 <span>New Workflow</span>
#               </button>
#             </div>
#           </div>
#         </div>
#       </:page_header>

#       <div class="space-y-8">
#         <section>
#           <div class="card relative overflow-hidden transition-all duration-300 border border-base-300 rounded-2xl shadow-sm ring-1 ring-base-300/70 bg-base-100 p-3">
#             <div class="flex items-center justify-between px-4 text-sm"></div>
#             <.data_table
#               id="workflows"
#               rows={@streams.workflows}
#               rows_empty?={@workflows_empty?}
#               tbody_class="divide-y divide-base-200"
#               row_click={&navigate_to_workflow/1}
#               row_class="cursor-pointer hover:bg-neutral/10"
#             >
#               <:col :let={workflow} label="Workflow">
#                 <div class="space-y-2">
#                   <div class="flex flex-wrap items-center gap-2">
#                     <p class="text-sm font-semibold text-base-content">{workflow.name}</p>
#                     <span :if={workflow.current_version_tag} class="badge badge-ghost badge-xs">
#                       v{workflow.current_version_tag}
#                     </span>
#                   </div>
#                   <p class="text-xs leading-relaxed text-base-content/70">
#                     {workflow.description}
#                   </p>
#                   <p class="text-[11px] font-mono uppercase tracking-wide text-base-content/50">
#                     {short_id(workflow.id)}
#                   </p>
#                 </div>
#               </:col>

#               <:col :let={workflow} label="Trigger" width="16%">
#                 <div class="flex items-center gap-2 text-xs font-medium text-base-content/80">
#                   <.icon name="hero-bolt" class="size-4 opacity-70" />
#                   <span>{trigger_label(workflow)}</span>
#                 </div>
#               </:col>

#               <:col :let={workflow} label="Status" width="14%" align="center">
#                 <span
#                   class={["badge badge-sm", status_badge_class(workflow.status)]}
#                   data-role="status"
#                   data-status={workflow.status}
#                 >
#                   {status_label(workflow.status)}
#                 </span>
#               </:col>

#               <:col :let={workflow} label="Updated" width="18%">
#                 <div class="flex items-center gap-2 text-xs text-base-content/70">
#                   <.icon name="hero-clock" class="size-4 opacity-70" />
#                   <span>{formatted_timestamp(workflow.updated_at)}</span>
#                 </div>
#               </:col>

#               <:col :let={workflow} label="Created" width="18%">
#                 <div class="text-xs text-base-content/60">
#                   {formatted_timestamp(workflow.inserted_at)}
#                 </div>
#               </:col>

#               <:col :let={workflow} label="Actions" width="12%" align="center">
#                 <div class="relative">
#                   <button
#                     type="button"
#                     class="btn btn-ghost btn-sm btn-circle"
#                     popovertarget={"workflow-actions-#{workflow.id}"}
#                     style={"anchor-name:--workflow-actions-#{workflow.id}"}
#                     @click.stop
#                   >
#                     <.icon name="hero-ellipsis-horizontal" class="size-4" />
#                   </button>
#                   <ul
#                     class="dropdown menu w-52 rounded-box bg-base-100 shadow-sm"
#                     popover
#                     id={"workflow-actions-#{workflow.id}"}
#                     style={"position-anchor:--workflow-actions-#{workflow.id}"}
#                   >
#                     <li>
#                       <button
#                         type="button"
#                         phx-click="open_workflow"
#                         phx-value-workflow_id={workflow.id}
#                         class="flex items-center gap-2"
#                       >
#                         <.icon name="hero-eye" class="size-4" />
#                         <span>Open</span>
#                       </button>
#                     </li>
#                     <li>
#                       <button
#                         type="button"
#                         phx-click="duplicate_workflow"
#                         phx-value-workflow_id={workflow.id}
#                         class="flex items-center gap-2"
#                       >
#                         <.icon name="hero-document-duplicate" class="size-4" />
#                         <span>Duplicate</span>
#                       </button>
#                     </li>
#                     <li>
#                       <button
#                         type="button"
#                         phx-click="archive_workflow"
#                         phx-value-workflow_id={workflow.id}
#                         class="flex items-center gap-2 text-error"
#                       >
#                         <.icon name="hero-archive-box" class="size-4" />
#                         <span>Archive</span>
#                       </button>
#                     </li>
#                   </ul>
#                 </div>
#               </:col>

#               <:empty_state>
#                 <div class="flex flex-col items-center justify-center gap-3 py-10 text-base-content/70">
#                   <div class="rounded-full bg-base-200 p-3">
#                     <.icon name="hero-rocket-launch" class="size-6" />
#                   </div>
#                   <div class="space-y-1 text-center">
#                     <p class="text-sm font-semibold text-base-content">No workflows yet</p>
#                     <p class="text-xs">Create one above to get started.</p>
#                   </div>
#                 </div>
#               </:empty_state>
#             </.data_table>
#           </div>
#         </section>
#       </div>

#       <%!-- Create Workflow Modal --%>
#       <div
#         :if={@show_create_modal}
#         class="modal modal-open"
#         phx-click="close_create_modal"
#         id="create-workflow-modal"
#       >
#         <div
#           class="modal-box max-w-2xl"
#           phx-click={JS.exec("phx-remove", to: "#create-workflow-modal")}
#         >
#           <div class="flex items-center justify-between pb-4 border-b border-base-200">
#             <div class="space-y-1">
#               <h3 class="text-lg font-semibold text-base-content">Create New Workflow</h3>
#               <p class="text-sm text-base-content/70">
#                 Give your workflow a name and description to get started.
#               </p>
#             </div>
#             <button
#               type="button"
#               phx-click="close_create_modal"
#               class="btn btn-ghost btn-sm btn-circle"
#               aria-label="Close"
#             >
#               <.icon name="hero-x-mark" class="size-5" />
#             </button>
#           </div>

#           <.form
#             :if={@form}
#             for={@form}
#             id="create-workflow-form"
#             phx-change="validate_workflow"
#             phx-submit="create_workflow"
#             class="space-y-6 py-6"
#           >
#             <.input
#               field={@form[:name]}
#               type="text"
#               label="Workflow Name"
#               placeholder="e.g., Daily Report Generator"
#               required
#             />

#             <.input
#               field={@form[:description]}
#               type="textarea"
#               label="Description"
#               placeholder="Describe what this workflow does and when to use it..."
#             />

#             <div class="flex items-center justify-end gap-3 pt-4 border-t border-base-200">
#               <button
#                 type="button"
#                 phx-click="close_create_modal"
#                 class="btn btn-ghost"
#               >
#                 Cancel
#               </button>
#               <button
#                 type="submit"
#                 class="btn btn-primary gap-2"
#               >
#                 <.icon name="hero-plus" class="size-4" />
#                 <span>Create Workflow</span>
#               </button>
#             </div>
#           </.form>
#         </div>
#       </div>
#     </Layouts.app>
#     """
#   end

#   defp trigger_label(workflow) do
#     workflow = Imgd.Repo.preload(workflow, :draft)
#     draft = workflow.draft || %{triggers: []}

#     case draft.triggers do
#       [trigger | _] ->
#         trigger.type
#         |> to_string()
#         |> String.capitalize()

#       _ ->
#         "Manual"
#     end
#   end

#   defp sort_workflows(workflows) do
#     Enum.sort_by(
#       workflows,
#       fn workflow ->
#         workflow.updated_at || workflow.inserted_at
#       end,
#       {:desc, DateTime}
#     )
#   end

#   defp navigate_to_workflow({_, workflow}), do: JS.navigate(~p"/workflows/#{workflow.id}")
#   defp navigate_to_workflow(workflow), do: JS.navigate(~p"/workflows/#{workflow.id}")
# end
