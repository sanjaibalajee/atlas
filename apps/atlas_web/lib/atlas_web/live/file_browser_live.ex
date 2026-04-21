defmodule AtlasWeb.FileBrowserLive do
  @moduledoc """
  Live file browser: sidebar of locations, main pane of files, detail modal.

  Three `live_action`s share the same LiveView module so the sidebar stays
  mounted across navigation (no flash, no re-fetch, no unsubscribe churn):

    * `:index` (`/`) — sidebar only; empty state when no locations.
    * `:show` (`/l/:location_id`) — sidebar + file list or grid.
    * `:file_detail` (`/l/:location_id/f/:file_id`) — same plus a modal.

  Live updates flow from the projector:

      projector commits → Phoenix.PubSub(Atlas.PubSub, "location:#\{id}")
                        → handle_info({:file_changed, _})
                        → stream_insert / stream_delete_by_dom_id

  Messages are gated on `socket.assigns.location_id` so messages that
  straddle a `handle_params` topic swap are dropped rather than leaking
  rows from the previous location.
  """

  use AtlasWeb, :live_view

  alias Atlas.Library
  alias AtlasWeb.FileHelpers

  @default_limit 100
  @allowed_sorts ~w(path size mtime_us indexed_at_us)a
  @allowed_views ~w(list grid)a

  # --- Lifecycle ---

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Atlas.PubSub, Library.locations_topic())
    end

    locations = Library.list_locations()

    started = System.monotonic_time(:microsecond)

    socket =
      socket
      |> assign(
        locations: locations,
        location: nil,
        location_id: nil,
        location_topic: nil,
        stats: empty_stats(),
        sort: :path,
        order: :asc,
        view: :list,
        cursor: nil,
        eol?: false,
        visible_ids: MapSet.new(),
        pending_new: 0,
        selected: nil,
        show_add_form: false,
        page_title: "Atlas"
      )
      |> stream(:files, [], dom_id: &dom_id(&1.id))

    :telemetry.execute(
      [:atlas_web, :file_browser, :mount],
      %{duration_us: System.monotonic_time(:microsecond) - started},
      %{action: :mount, location_id: nil}
    )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action

    socket =
      socket
      |> apply_view_and_sort(params)
      |> apply_action(action, params)

    {:noreply, socket}
  end

  # --- Action dispatch ---

  defp apply_action(socket, :index, _params) do
    socket
    |> maybe_unsubscribe_location()
    |> stream(:files, [], reset: true)
    |> assign(
      location: nil,
      location_id: nil,
      location_topic: nil,
      stats: empty_stats(),
      visible_ids: MapSet.new(),
      pending_new: 0,
      cursor: nil,
      eol?: false,
      selected: nil,
      page_title: "Atlas"
    )
  end

  defp apply_action(socket, :show, params) do
    switch_location(socket, params)
  end

  defp apply_action(socket, :file_detail, params) do
    socket = switch_location(socket, params)

    case parse_id(params["file_id"]) do
      {:ok, id} ->
        assign(socket, :selected, Library.get_file(id))

      :error ->
        socket
        |> put_flash(:error, "Invalid file id.")
        |> assign(:selected, nil)
    end
  end

  # --- Location switch ---
  # Strict order: unsubscribe → reset stream → reassign → subscribe → reload.
  # Malformed ids fall through to the :index-style empty state + flash so a
  # bad URL never crashes the LiveView.

  defp switch_location(socket, %{"location_id" => id_str}) do
    case parse_id(id_str) do
      :error ->
        socket
        |> put_flash(:error, "Invalid location id.")
        |> apply_action(:index, %{})

      {:ok, id} ->
        switch_to_location(socket, id)
    end
  end

  defp switch_to_location(socket, id) do
    if socket.assigns.location_id == id do
      # Already on this location — just refresh stats (e.g., after a
      # LocationScanCompleted broadcast patched us).
      assign(socket, :stats, Library.file_stats(id))
    else
      location = Enum.find(socket.assigns.locations, &(&1.id == id))

      socket
      |> maybe_unsubscribe_location()
      |> stream(:files, [], reset: true, dom_id: &dom_id(&1.id))
      |> assign(
        location: location,
        location_id: id,
        location_topic: Library.location_topic(id),
        stats: Library.file_stats(id),
        visible_ids: MapSet.new(),
        pending_new: 0,
        cursor: nil,
        eol?: false,
        selected: nil,
        page_title: location && "#{FileHelpers.location_name(location.path)} · Atlas"
      )
      |> maybe_subscribe_location()
      |> load_next_page(:initial_page)
    end
  end

  defp maybe_unsubscribe_location(%{assigns: %{location_topic: nil}} = socket), do: socket

  defp maybe_unsubscribe_location(%{assigns: %{location_topic: topic}} = socket) do
    Phoenix.PubSub.unsubscribe(Atlas.PubSub, topic)
    socket
  end

  defp maybe_subscribe_location(%{assigns: %{location_topic: nil}} = socket), do: socket

  defp maybe_subscribe_location(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Atlas.PubSub, socket.assigns.location_topic)
    end

    socket
  end

  # --- Safe id parsing ---

  # URL params are strings; LiveView must survive garbage. Accepts only
  # "42" (exact integer, no trailing junk).
  defp parse_id(nil), do: :error

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {id, ""} when id >= 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  # --- View / sort / order parsing ---

  defp apply_view_and_sort(socket, params) do
    sort = parse_sort(params["sort"]) || socket.assigns.sort
    order = parse_order(params["dir"]) || socket.assigns.order
    view = parse_view(params["view"]) || socket.assigns.view

    sort_or_order_changed? =
      sort != socket.assigns.sort or order != socket.assigns.order

    # Re-stream on view change too: LiveStream only emits freshly-inserted
    # rows. Switching to a new container (list ↔ grid) means the new body
    # has nothing to render unless we replay the current page.
    view_changed? = view != socket.assigns.view

    socket = assign(socket, sort: sort, order: order, view: view)

    if (sort_or_order_changed? or view_changed?) and socket.assigns.location_id do
      socket
      |> stream(:files, [], reset: true, dom_id: &dom_id(&1.id))
      |> assign(visible_ids: MapSet.new(), pending_new: 0, cursor: nil, eol?: false)
      |> load_next_page(:initial_page)
    else
      socket
    end
  end

  defp parse_sort(nil), do: nil

  defp parse_sort(str) do
    atom = String.to_existing_atom(str)
    if atom in @allowed_sorts, do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp parse_order("asc"), do: :asc
  defp parse_order("desc"), do: :desc
  defp parse_order(_), do: nil

  defp parse_view(str) when is_binary(str) do
    atom = String.to_existing_atom(str)
    if atom in @allowed_views, do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp parse_view(_), do: nil

  # --- Pagination ---

  defp load_next_page(%{assigns: %{location_id: nil}} = socket, _cause), do: socket

  defp load_next_page(socket, cause) do
    %{rows: rows, cursor: cursor} =
      Library.list_files(socket.assigns.location_id,
        limit: @default_limit,
        sort_by: socket.assigns.sort,
        order: socket.assigns.order,
        after: socket.assigns.cursor
      )

    :telemetry.execute(
      [:atlas_web, :file_browser, :stream_insert],
      %{count: length(rows)},
      %{location_id: socket.assigns.location_id, cause: cause}
    )

    socket =
      Enum.reduce(rows, socket, fn file, acc ->
        acc
        |> stream_insert(:files, file)
        |> update(:visible_ids, &MapSet.put(&1, file.id))
      end)

    case cursor do
      :eol -> assign(socket, eol?: true, cursor: nil)
      cursor -> assign(socket, cursor: cursor, eol?: false)
    end
  end

  # --- Messages ---

  @impl true
  def handle_info({:file_changed, %{location_id: loc_id} = msg}, socket) do
    if loc_id == socket.assigns.location_id do
      socket =
        socket
        |> handle_file_change(msg)
        |> maybe_refresh_current_stats()

      {:noreply, socket}
    else
      # Message from a previously-subscribed location that beat unsubscribe
      # to our mailbox. Drop it — the current topic defines the truth.
      {:noreply, socket}
    end
  end

  def handle_info({:location_changed, _}, socket) do
    locations = Library.list_locations()

    socket =
      assign(socket, :locations, locations)
      # If the currently-shown location was tombstoned, drop stats to zero.
      |> maybe_refresh_current_stats()

    {:noreply, socket}
  end

  def handle_info({:scan_progress, _}, socket) do
    # M2.7 renders a progress bar here. For M2.3, drop silently — we've
    # plumbed the topic so subscribing later is template-only.
    {:noreply, socket}
  end

  defp maybe_refresh_current_stats(%{assigns: %{location_id: nil}} = socket), do: socket

  defp maybe_refresh_current_stats(socket) do
    assign(socket, :stats, Library.file_stats(socket.assigns.location_id))
  end

  defp handle_file_change(socket, %{kind: :deleted, file_id: id}) do
    socket
    |> stream_delete_by_dom_id(:files, dom_id(id))
    |> update(:visible_ids, &MapSet.delete(&1, id))
  end

  defp handle_file_change(socket, %{kind: :moved_out, file_id: id}) do
    handle_file_change(socket, %{kind: :deleted, file_id: id})
  end

  defp handle_file_change(socket, %{file_id: nil}), do: socket

  defp handle_file_change(socket, %{kind: kind, file_id: id})
       when kind in [:indexed, :modified, :moved_in] do
    cond do
      MapSet.member?(socket.assigns.visible_ids, id) ->
        case Library.get_file(id) do
          nil ->
            socket

          %{file: file} ->
            :telemetry.execute(
              [:atlas_web, :file_browser, :stream_insert],
              %{count: 1},
              %{location_id: socket.assigns.location_id, cause: :live}
            )

            stream_insert(socket, :files, file)
        end

      true ->
        # Row is outside the loaded window. Record a pending-new count and
        # let the user refresh; see plan's "N new files — refresh" toast.
        update(socket, :pending_new, &(&1 + 1))
    end
  end

  # --- Events ---

  @impl true
  def handle_event("load_more", _params, socket) do
    if socket.assigns.eol? or socket.assigns.location_id == nil do
      {:noreply, socket}
    else
      {:noreply, load_next_page(socket, :load_more)}
    end
  end

  def handle_event("refresh", _params, socket) do
    if socket.assigns.location_id do
      socket =
        socket
        |> stream(:files, [], reset: true, dom_id: &dom_id(&1.id))
        |> assign(visible_ids: MapSet.new(), pending_new: 0, cursor: nil, eol?: false)
        |> load_next_page(:initial_page)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("sort", %{"by" => col}, socket) do
    sort = parse_sort(col) || socket.assigns.sort

    order =
      if sort == socket.assigns.sort do
        flip(socket.assigns.order)
      else
        :asc
      end

    {:noreply, push_patch(socket, to: current_path(socket, sort: sort, dir: order))}
  end

  def handle_event("view", %{"mode" => mode}, socket) do
    view = parse_view(mode) || socket.assigns.view
    {:noreply, push_patch(socket, to: current_path(socket, view: view))}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/l/#{socket.assigns.location_id}" <> query_string(socket)
     )}
  end

  # --- Location management (M2.4) ---

  def handle_event("toggle_add_form", _params, socket) do
    {:noreply, update(socket, :show_add_form, &(not &1))}
  end

  def handle_event("add_location", %{"path" => raw_path}, socket) do
    path = raw_path |> to_string() |> String.trim()

    case validate_new_location_path(path) do
      {:ok, expanded} ->
        case Atlas.Locations.add(expanded) do
          {:ok, location} ->
            {:noreply,
             socket
             |> assign(:show_add_form, false)
             |> assign(:locations, Library.list_locations())
             |> put_flash(:info, "Watching #{location.path}")
             |> push_patch(to: ~p"/l/#{location.id}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, humanize_add_error(reason))}
        end

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("remove_location", %{"id" => id_str}, socket) do
    with {:ok, id} <- parse_id(id_str),
         %{path: path} <- Enum.find(socket.assigns.locations, &(&1.id == id)) do
      case Atlas.Locations.remove(path) do
        :ok ->
          # If the removed location was the one being viewed, hop back to the
          # :index action so we don't render a dangling pane.
          socket =
            if socket.assigns.location_id == id do
              push_patch(socket, to: ~p"/")
            else
              socket
            end

          {:noreply,
           socket
           |> assign(:locations, Library.list_locations())
           |> put_flash(:info, "Stopped watching #{path}")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not remove: #{inspect(reason)}")}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Unknown location.")}
    end
  end

  # Reject clearly-bad paths before touching the log. Prevents orphan
  # LocationAdded events for typos / missing dirs. `Locations.add/1` is
  # otherwise idempotent so a repeat of an already-watched path is harmless.
  defp validate_new_location_path(""), do: {:error, "Path is required."}

  defp validate_new_location_path(path) do
    expanded = Path.expand(path)

    case File.stat(expanded) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, expanded}
      {:ok, %File.Stat{type: other}} -> {:error, "Not a directory (#{other}): #{expanded}"}
      {:error, :enoent} -> {:error, "Path does not exist: #{expanded}"}
      {:error, reason} -> {:error, "Cannot read path: #{inspect(reason)}"}
    end
  end

  defp humanize_add_error({:not_a_directory, path}), do: "Not a directory: #{path}"
  defp humanize_add_error(:enoent), do: "Path not found."
  defp humanize_add_error(reason), do: "Could not add location: #{inspect(reason)}"

  # --- URL helpers ---

  defp current_path(socket, overrides) do
    params =
      %{
        sort: socket.assigns.sort,
        dir: socket.assigns.order,
        view: socket.assigns.view
      }
      |> Map.merge(Map.new(overrides))
      |> Map.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)

    base =
      if socket.assigns.location_id do
        ~p"/l/#{socket.assigns.location_id}"
      else
        ~p"/"
      end

    base <> "?" <> URI.encode_query(params)
  end

  defp query_string(socket) do
    params =
      %{sort: socket.assigns.sort, dir: socket.assigns.order, view: socket.assigns.view}
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)

    "?" <> URI.encode_query(params)
  end

  defp flip(:asc), do: :desc
  defp flip(:desc), do: :asc

  defp dom_id(id) when is_integer(id), do: "file-#{id}"

  defp empty_stats,
    do: %{files_count: 0, bytes_total: 0, last_scanned_at_us: nil, watching?: false}

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-screen flex" id="file-browser-root">
        <aside class="w-64 shrink-0 border-r border-base-300 bg-base-100 p-4 overflow-y-auto">
          <div class="flex items-center justify-between mb-4">
            <span class="font-semibold text-lg">Atlas</span>
            <button
              type="button"
              class="btn btn-xs btn-ghost"
              phx-click="toggle_add_form"
              aria-label="Add location"
              data-testid="toggle-add-form"
            >
              <.icon
                name={if @show_add_form, do: "hero-x-mark", else: "hero-plus"}
                class="size-4"
              />
            </button>
          </div>

          <.add_location_form :if={@show_add_form} />

          <.sidebar_locations locations={@locations} current_id={@location_id} />
        </aside>

        <main class="flex-1 p-6 overflow-y-auto">
          <%= cond do %>
            <% @locations == [] -> %>
              <.empty_state />
            <% @location_id == nil -> %>
              <.pick_location_hint />
            <% true -> %>
              <.location_pane
                location={@location}
                stats={@stats}
                view={@view}
                sort={@sort}
                order={@order}
                pending_new={@pending_new}
                eol?={@eol?}
                streams={@streams}
              />
          <% end %>
        </main>
      </div>

      <.file_modal
        :if={@live_action == :file_detail and @selected}
        selected={@selected}
        location={@location}
      />
    </Layouts.app>
    """
  end

  # --- Components ---

  attr :locations, :list, required: true
  attr :current_id, :any, required: true

  defp sidebar_locations(assigns) do
    ~H"""
    <div :if={@locations == []} class="text-sm text-base-content/70">
      No locations yet.
    </div>
    <ul class="menu menu-sm bg-base-100 w-full" data-testid="sidebar-locations">
      <li :for={loc <- @locations} data-testid={"sidebar-location-#{loc.id}"}>
        <div class="flex items-center gap-1 rounded hover:bg-base-200 pr-1">
          <.link
            patch={~p"/l/#{loc.id}"}
            class={[
              "flex-1 min-w-0 flex items-center gap-2 px-2 py-1 rounded",
              loc.id == @current_id && "menu-active"
            ]}
          >
            <.icon name="hero-folder" class="size-4 shrink-0" />
            <span class="truncate">{AtlasWeb.FileHelpers.location_name(loc.path)}</span>
          </.link>
          <button
            type="button"
            class="btn btn-xs btn-ghost opacity-40 hover:opacity-100"
            phx-click="remove_location"
            phx-value-id={loc.id}
            data-confirm={"Stop watching #{loc.path}?"}
            aria-label="Remove location"
            title={"Stop watching #{loc.path}"}
            data-testid={"remove-location-#{loc.id}"}
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>
      </li>
    </ul>
    """
  end

  defp add_location_form(assigns) do
    ~H"""
    <form
      phx-submit="add_location"
      class="mb-4 space-y-2"
      data-testid="add-location-form"
    >
      <label class="text-xs font-medium text-base-content/70">
        Path to watch
      </label>
      <input
        type="text"
        name="path"
        placeholder="/Users/you/Pictures"
        class="input input-sm input-bordered w-full"
        required
        autocomplete="off"
        spellcheck="false"
        phx-mounted={Phoenix.LiveView.JS.focus()}
      />
      <button type="submit" class="btn btn-sm btn-primary w-full">
        Add
      </button>
    </form>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div data-testid="empty-state" class="max-w-lg mx-auto text-center mt-24 space-y-3">
      <.icon name="hero-folder-plus" class="size-12 text-base-content/60" />
      <h2 class="text-xl font-semibold">No locations yet</h2>
      <p class="text-base-content/70">
        Add a directory with
        <code class="kbd kbd-sm">mix atlas.watch &lt;path&gt;</code>
        or
        <code class="kbd kbd-sm">bin/atlas locations add &lt;path&gt;</code>.
        UI coming in M2.4.
      </p>
    </div>
    """
  end

  defp pick_location_hint(assigns) do
    ~H"""
    <div class="max-w-md mx-auto text-center mt-24 text-base-content/70">
      Select a location from the sidebar.
    </div>
    """
  end

  attr :location, :map, required: true
  attr :stats, :map, required: true
  attr :view, :atom, required: true
  attr :sort, :atom, required: true
  attr :order, :atom, required: true
  attr :pending_new, :integer, required: true
  attr :eol?, :boolean, required: true
  attr :streams, :map, required: true

  defp location_pane(assigns) do
    ~H"""
    <header class="flex items-center justify-between gap-6 pb-4" data-testid="location-header">
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <h1 class="text-lg font-semibold truncate" data-testid="location-path">
            {@location.path}
          </h1>
          <span
            :if={@stats.watching?}
            class="badge badge-success badge-sm gap-1"
            title="Filesystem watcher active — changes stream into the UI in real time."
          >
            <span class="relative flex size-2">
              <span class="absolute inline-flex size-2 animate-ping rounded-full bg-success/75"></span>
              <span class="relative inline-flex size-2 rounded-full bg-success"></span>
            </span>
            Live
          </span>
          <span
            :if={not @stats.watching?}
            class="badge badge-ghost badge-sm"
            title="No watcher running for this location — view shows last-scanned state only."
          >
            Not watching
          </span>
        </div>
        <p class="text-sm text-base-content/70" data-testid="location-stats">
          <span data-testid="files-count">{@stats.files_count}</span>
          files · <span data-testid="bytes-total">
            {AtlasWeb.FileHelpers.format_size(@stats.bytes_total)}
          </span>
          <span :if={@stats.last_scanned_at_us}>
            · last full scan {AtlasWeb.FileHelpers.format_relative_time(@stats.last_scanned_at_us)}
          </span>
        </p>
      </div>
      <div class="flex items-center gap-2">
        <div class="join">
          <button
            class={["btn btn-sm join-item", @view == :list && "btn-active"]}
            phx-click="view"
            phx-value-mode="list"
          >
            <.icon name="hero-list-bullet" class="size-4" /> List
          </button>
          <button
            class={["btn btn-sm join-item", @view == :grid && "btn-active"]}
            phx-click="view"
            phx-value-mode="grid"
          >
            <.icon name="hero-squares-2x2" class="size-4" /> Grid
          </button>
        </div>
      </div>
    </header>

    <div :if={@pending_new > 0} data-testid="pending-new-alert" class="alert alert-info mb-4">
      <.icon name="hero-arrow-path" class="size-4" />
      <span>{@pending_new} new files outside current page</span>
      <button class="btn btn-sm btn-ghost" phx-click="refresh">Refresh</button>
    </div>

    <.list_body
      :if={@view != :grid}
      streams={@streams}
      location={@location}
      sort={@sort}
      order={@order}
      eol?={@eol?}
    />
    <.grid_body
      :if={@view == :grid}
      streams={@streams}
      location={@location}
      eol?={@eol?}
    />
    """
  end

  attr :streams, :map, required: true
  attr :location, :map, required: true
  attr :sort, :atom, required: true
  attr :order, :atom, required: true
  attr :eol?, :boolean, required: true

  defp list_body(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-zebra w-full">
        <thead>
          <tr>
            <th><.sort_header col={:path} sort={@sort} order={@order}>Path</.sort_header></th>
            <th class="w-32">
              <.sort_header col={:size} sort={@sort} order={@order}>Size</.sort_header>
            </th>
            <th class="w-32">
              <.sort_header col={:mtime_us} sort={@sort} order={@order}>Modified</.sort_header>
            </th>
            <th class="w-32">Hash</th>
          </tr>
        </thead>
        <tbody id="files" phx-update="stream">
          <tr
            :for={{dom_id, file} <- @streams.files}
            id={dom_id}
            class="hover cursor-pointer"
            phx-click={JS.patch(~p"/l/#{@location.id}/f/#{file.id}")}
          >
            <td class="font-mono text-sm truncate max-w-[40rem]">
              {AtlasWeb.FileHelpers.relative_path(file.path, @location.path)}
            </td>
            <td>{AtlasWeb.FileHelpers.format_size(file.size)}</td>
            <td>{AtlasWeb.FileHelpers.format_relative_time(file.mtime_us)}</td>
            <td class="font-mono text-xs">
              {AtlasWeb.FileHelpers.short_hash(file.root_hash)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <div
      :if={not @eol?}
      id="files-sentinel-list"
      phx-viewport-bottom="load_more"
      class="h-8"
    />
    """
  end

  attr :col, :atom, required: true
  attr :sort, :atom, required: true
  attr :order, :atom, required: true
  slot :inner_block, required: true

  defp sort_header(assigns) do
    ~H"""
    <button type="button" class="flex items-center gap-1 cursor-pointer" phx-click="sort" phx-value-by={@col}>
      {render_slot(@inner_block)}
      <.icon
        :if={@sort == @col}
        name={if(@order == :asc, do: "hero-chevron-up", else: "hero-chevron-down")}
        class="size-3"
      />
    </button>
    """
  end

  attr :streams, :map, required: true
  attr :location, :map, required: true
  attr :eol?, :boolean, required: true

  defp grid_body(assigns) do
    ~H"""
    <div
      id="files"
      phx-update="stream"
      class="grid grid-cols-[repeat(auto-fill,minmax(10rem,1fr))] gap-3"
    >
      <div
        :for={{dom_id, file} <- @streams.files}
        id={dom_id}
        phx-click={JS.patch(~p"/l/#{@location.id}/f/#{file.id}")}
        class="card bg-base-100 border border-base-300 hover:border-base-content/20 cursor-pointer p-3 space-y-2"
      >
        <div class="aspect-square bg-base-200 rounded flex items-center justify-center">
          <.icon name="hero-document" class="size-8 text-base-content/40" />
        </div>
        <div class="text-sm font-medium truncate" title={file.path}>
          {AtlasWeb.FileHelpers.relative_path(file.path, @location.path)}
        </div>
        <div class="text-xs text-base-content/60 flex justify-between">
          <span>{AtlasWeb.FileHelpers.format_size(file.size)}</span>
          <span class="font-mono">{AtlasWeb.FileHelpers.short_hash(file.root_hash)}</span>
        </div>
      </div>
    </div>

    <div
      :if={not @eol?}
      id="files-sentinel-grid"
      phx-viewport-bottom="load_more"
      class="h-8"
    />
    """
  end

  attr :selected, :map, required: true
  attr :location, :map, required: true

  defp file_modal(assigns) do
    ~H"""
    <dialog id="file-detail" class="modal modal-open" phx-mounted={JS.focus(to: "#file-detail")}>
      <div class="modal-box max-w-2xl">
        <form method="dialog">
          <button
            type="button"
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_modal"
            aria-label="Close"
          >
            ✕
          </button>
        </form>
        <h3 class="font-semibold text-lg truncate" title={@selected.file.path}>
          {Path.basename(@selected.file.path)}
        </h3>
        <p class="text-sm text-base-content/60 truncate" title={@selected.file.path}>
          {@selected.file.path}
        </p>
        <div class="divider my-2"></div>
        <dl class="grid grid-cols-[8rem_1fr] gap-y-1 text-sm">
          <dt class="text-base-content/70">Size</dt>
          <dd>{AtlasWeb.FileHelpers.format_size(@selected.file.size)}</dd>

          <dt class="text-base-content/70">Modified</dt>
          <dd>{AtlasWeb.FileHelpers.format_relative_time(@selected.file.mtime_us)}</dd>

          <dt class="text-base-content/70">Indexed</dt>
          <dd>{AtlasWeb.FileHelpers.format_relative_time(@selected.file.indexed_at_us)}</dd>

          <dt class="text-base-content/70">Chunks</dt>
          <dd>{@selected.chunk_count}</dd>

          <dt class="text-base-content/70">Root hash</dt>
          <dd class="font-mono text-xs break-all">
            {AtlasWeb.FileHelpers.full_hash(@selected.file.root_hash)}
          </dd>
        </dl>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="close_modal">close</button>
      </form>
    </dialog>
    """
  end
end
