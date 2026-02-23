package engine

import "core:mem"
import "core:os"
import "core:thread"
import glfw "vendor:glfw"
import vk "vendor:vulkan"
import shared "../shared"

// -----------------------------------------------------------------------
// Engine API callbacks (called by the game via function pointers)
// -----------------------------------------------------------------------

App_Callback_Context :: struct {
	commands: ^Frame_Commands,
	window:   glfw.WindowHandle,
	dt:       f32,
}

@(private)
app_callback_context: App_Callback_Context

engine_draw_quad :: proc(x, y, width, height: f32, r, g, b, a: f32) {
	if app_callback_context.commands == nil {
		return
	}

	append(&app_callback_context.commands.quads, Quad_Command {
		rect  = {x, y, width, height},
		color = {r, g, b, a},
	})
}

engine_set_clear_color :: proc(r, g, b, a: f32) {
	if app_callback_context.commands == nil {
		return
	}
	app_callback_context.commands.clear_color = {r, g, b, a}
}

engine_log :: proc(message: string) {
	log_infof("[game] %s", message)
}

engine_get_dt :: proc() -> f32 {
	return app_callback_context.dt
}

engine_is_key_down :: proc(key: i32) -> bool {
	if app_callback_context.window == nil {
		return false
	}
	return glfw.GetKey(app_callback_context.window, key) == glfw.PRESS
}

make_engine_api :: proc() -> shared.Engine_API {
	return shared.Engine_API {
		api_version     = shared.GAME_API_VERSION,
		draw_quad       = engine_draw_quad,
		set_clear_color = engine_set_clear_color,
		log             = engine_log,
		get_dt          = engine_get_dt,
		is_key_down     = engine_is_key_down,
	}
}

// -----------------------------------------------------------------------
// Game module paths
// -----------------------------------------------------------------------

game_library_source_path :: proc() -> string {
	when ODIN_OS == .Windows {
		return "bin/game.dll"
	} else when ODIN_OS == .Darwin {
		return "bin/libgame.dylib"
	} else {
		return "bin/libgame.so"
	}
}

game_library_loaded_path :: proc() -> string {
	when ODIN_OS == .Windows {
		return "bin/game_loaded.dll"
	} else when ODIN_OS == .Darwin {
		return "bin/libgame_loaded.dylib"
	} else {
		return "bin/libgame_loaded.so"
	}
}

// -----------------------------------------------------------------------
// Engine state
// -----------------------------------------------------------------------

MAX_FRAMES_IN_FLIGHT :: 2

Engine :: struct {
	// Core Vulkan
	instance:        vk.Instance,
	physical_device: vk.PhysicalDevice,
	device_props:    vk.PhysicalDeviceProperties,

	// Window & surface
	window:  glfw.WindowHandle,
	surface: vk.SurfaceKHR,

	// GPU context (logical device + queues)
	gpu_context:          GpuContext,
	queue_family_indices: QueueFamilyIndices,

	// Swapchain
	swapchain_allocator: mem.Allocator,
	swapchain_context:   SwapchainContext,

	// Shaders & pipeline
	vert_module:       vk.ShaderModule,
	frag_module:       vk.ShaderModule,
	shader_stages:     [2]vk.PipelineShaderStageCreateInfo,
	pipeline_layout:   vk.PipelineLayout,
	graphics_pipeline: vk.Pipeline,

	// Bindless resources
	descriptor_layout: vk.DescriptorSetLayout,
	descriptor_pool:   vk.DescriptorPool,
	descriptor_sets:   [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	quad_ssbos:        [MAX_FRAMES_IN_FLIGHT]Mapped_Buffer,

	// Commands (per frame, per lane)
	command_pools: [MAX_FRAMES_IN_FLIGHT][MAX_LANES]vk.CommandPool,
	cmds:          [MAX_FRAMES_IN_FLIGHT][MAX_LANES]vk.CommandBuffer,

	// Synchronization (per frame)
	image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	render_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	in_flight_fences:           [MAX_FRAMES_IN_FLIGHT]vk.Fence,

	// Frame tracking
	current_frame: u32,
	quit:          bool,
	prev_time:     f32,

	// Per-frame data
	frame_commands: Frame_Commands,

	// Game
	engine_api:  shared.Engine_API,
	game_module: Game_Module,
	game_memory: []byte,
}

// -----------------------------------------------------------------------
// Vulkan init steps (mirrors Vulkan Tutorial's initVulkan pattern)
// -----------------------------------------------------------------------

init_window :: proc(e: ^Engine) -> bool {
	if !glfw.Init() {
		log_error("glfwInit failed")
		return false
	}

	if !glfw.VulkanSupported() {
		log_error("GLFW reports Vulkan unsupported")
		return false
	}

	vk.load_proc_addresses_global(cast(rawptr)vkGetInstanceProcAddr)

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	e.window = glfw.CreateWindow(1280, 720, "Learning Vulkan", nil, nil)
	if e.window == nil {
		log_error("Failed to create a window")
		return false
	}

	return true
}

create_instance :: proc(e: ^Engine) -> bool {
	app_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "OdinGame",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "NoEngine",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_4,
	}

	glfw_extensions := glfw.GetRequiredInstanceExtensions()
	extensions := make([dynamic]cstring, len(glfw_extensions))
	copy(extensions[:], glfw_extensions)

	portability_ext: cstring = vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
	enable_portability := instance_extension_available(portability_ext)
	if enable_portability && !has_extension_name(glfw_extensions, portability_ext) {
		append(&extensions, portability_ext)
	}

	append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	validation_layers: []cstring = {"VK_LAYER_KHRONOS_validation"}

	create_flags := vk.InstanceCreateFlags{}
	if enable_portability {
		create_flags = {.ENUMERATE_PORTABILITY_KHR}
	}

	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		flags                   = create_flags,
		pApplicationInfo        = &app_info,
		enabledLayerCount       = u32(len(validation_layers)),
		ppEnabledLayerNames     = raw_data(validation_layers[:]),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions[:]),
	}

	if vk.CreateInstance(&create_info, nil, &e.instance) != .SUCCESS {
		log_error("vkCreateInstance failed")
		return false
	}

	vk.load_proc_addresses_instance(e.instance)
	return true
}

create_surface :: proc(e: ^Engine) -> bool {
	if glfw.CreateWindowSurface(e.instance, e.window, nil, &e.surface) != .SUCCESS {
		log_error("glfw.CreateWindowSurface failed")
		return false
	}
	return true
}

pick_device :: proc(e: ^Engine) -> bool {
	device, props, ok := pick_physical_device(e.instance)
	if !ok {
		log_error("Failed to find a suitable GPU device")
		return false
	}

	e.physical_device = device
	e.device_props = props

	device_name := string(cast(cstring)&e.device_props.deviceName[0])
	log_infof("Selected physical device %s", device_name)
	return true
}

create_logical_device :: proc(e: ^Engine) -> bool {
	gpu_ctx, ok := create_gpu_context(e.physical_device, e.surface)
	if !ok {
		log_error("Failed to create logical device")
		return false
	}
	e.gpu_context = gpu_ctx

	indices, ok_families := find_queue_families(e.physical_device, e.surface)
	if !ok_families {
		log_error("Failed to find swapchain queue families")
		return false
	}
	e.queue_family_indices = indices

	log_infof("Logical device created, graphics family=%d", e.gpu_context.graphics_family_index)
	return true
}

create_swapchain :: proc(e: ^Engine) -> bool {
	e.swapchain_allocator = swapchain_memory_init()

	ctx, ok := create_swapchain_context(
		e.gpu_context.device,
		e.physical_device,
		e.surface,
		e.queue_family_indices,
		e.swapchain_allocator,
	)
	if !ok {
		swapchain_memory_reset(e.swapchain_allocator)
		log_error("Failed to create swapchain context")
		return false
	}

	e.swapchain_context = ctx
	log_infof("Swapchain created with %d images", len(e.swapchain_context.images))
	return true
}

load_shaders :: proc(e: ^Engine) -> bool {
	vert_module, vert_stage, ok_vert := load_shader(e.gpu_context.device, "triangle.vert")
	frag_module, frag_stage, ok_frag := load_shader(e.gpu_context.device, "triangle.frag")

	if !ok_vert || !ok_frag {
		log_error("Failed to load shader modules")
		return false
	}

	e.vert_module = vert_module
	e.frag_module = frag_module
	e.shader_stages = {vert_stage, frag_stage}
	return true
}

create_pipeline_descriptor_layout :: proc(e: ^Engine) -> bool {
	layout, ok := create_descriptor_layout(e.gpu_context.device)
	if !ok {
		log_error("Failed to create descriptor set layout")
		return false
	}
	e.descriptor_layout = layout
	return true
}

create_bindless_resources :: proc(e: ^Engine) -> bool {
	ssbo_size := vk.DeviceSize(MAX_QUADS * size_of(Quad_Command))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		buf, ok := create_mapped_buffer(
			e.gpu_context.device,
			e.physical_device,
			ssbo_size,
			{.STORAGE_BUFFER},
		)
		if !ok {
			log_error("Failed to create quad SSBO")
			return false
		}
		e.quad_ssbos[i] = buf
	}

	pool, ok_pool := create_quad_descriptor_pool(e.gpu_context.device)
	if !ok_pool {
		log_error("Failed to create descriptor pool")
		return false
	}
	e.descriptor_pool = pool

	layouts: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		layouts[i] = e.descriptor_layout
	}
	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = e.descriptor_pool,
		descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
		pSetLayouts        = &layouts[0],
	}
	if vk.AllocateDescriptorSets(
		   e.gpu_context.device,
		   &alloc_info,
		   &e.descriptor_sets[0],
	   ) !=
	   .SUCCESS {
		log_error("Failed to allocate descriptor sets")
		return false
	}

	update_quad_descriptor_sets(
		e.gpu_context.device,
		e.descriptor_sets[:],
		e.quad_ssbos[:],
	)

	return true
}

create_pipeline :: proc(e: ^Engine) -> bool {
	layout, pipeline, ok := create_graphics_pipeline(
		e.gpu_context.device,
		e.swapchain_context.image_format,
		e.shader_stages[:],
		e.descriptor_layout,
	)
	if !ok {
		log_error("Failed to create the Vulkan graphics pipeline")
		return false
	}

	e.pipeline_layout = layout
	e.graphics_pipeline = pipeline
	return true
}

create_command_pools :: proc(e: ^Engine) -> bool {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = e.gpu_context.graphics_family_index,
	}
	for f in 0 ..< MAX_FRAMES_IN_FLIGHT {
		for l in 0 ..< MAX_LANES {
			if vk.CreateCommandPool(
				   e.gpu_context.device,
				   &pool_info,
				   nil,
				   &e.command_pools[f][l],
			   ) !=
			   .SUCCESS {
				log_error("Failed to create the Vulkan CommandPool")
				return false
			}
			alloc_info := vk.CommandBufferAllocateInfo {
				sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool        = e.command_pools[f][l],
				level              = .PRIMARY,
				commandBufferCount = 1,
			}
			if vk.AllocateCommandBuffers(
				   e.gpu_context.device,
				   &alloc_info,
				   &e.cmds[f][l],
			   ) !=
			   .SUCCESS {
				log_error("Failed to allocate Vulkan CommandBuffers")
				return false
			}
		}
	}
	return true
}

create_sync_objects :: proc(e: ^Engine) -> bool {
	semaphore_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if vk.CreateSemaphore(
			   e.gpu_context.device,
			   &semaphore_info,
			   nil,
			   &e.image_available_semaphores[i],
		   ) !=
		   .SUCCESS {
			log_error("Failed to create image_available semaphore")
			return false
		}
		if vk.CreateSemaphore(
			   e.gpu_context.device,
			   &semaphore_info,
			   nil,
			   &e.render_finished_semaphores[i],
		   ) !=
		   .SUCCESS {
			log_error("Failed to create render_finished semaphore")
			return false
		}
		if vk.CreateFence(e.gpu_context.device, &fence_info, nil, &e.in_flight_fences[i]) !=
		   .SUCCESS {
			log_error("Failed to create in_flight fence")
			return false
		}
	}
	return true
}

// init initialises the window and every Vulkan object the engine
// needs, in the same sequential order as the Vulkan Tutorial's initVulkan().
init :: proc(e: ^Engine) -> bool {
	if !init_window(e) do return false
	if !create_instance(e) do return false
	if !create_surface(e) do return false
	if !pick_device(e) do return false
	if !create_logical_device(e) do return false
	if !create_swapchain(e) do return false
	if !load_shaders(e) do return false
	if !create_pipeline_descriptor_layout(e) do return false
	if !create_pipeline(e) do return false
	if !create_command_pools(e) do return false
	if !create_sync_objects(e) do return false
	if !create_bindless_resources(e) do return false

	e.frame_commands = Frame_Commands {
		clear_color = {0.0, 0.0, 0.0, 1.0},
		quads       = make([dynamic]Quad_Command, context.allocator),
	}

	return true
}

// cleanup destroys all Vulkan objects in reverse init order.
cleanup :: proc(e: ^Engine) {
	if e.gpu_context.device != nil {
		vk.DeviceWaitIdle(e.gpu_context.device)
	}

	delete(e.frame_commands.quads)

	if e.gpu_context.device != nil {
		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
			destroy_mapped_buffer(e.gpu_context.device, &e.quad_ssbos[i])
		}
		if e.descriptor_pool != 0 {
			vk.DestroyDescriptorPool(e.gpu_context.device, e.descriptor_pool, nil)
		}
		if e.descriptor_layout != 0 {
			vk.DestroyDescriptorSetLayout(e.gpu_context.device, e.descriptor_layout, nil)
		}
		for f in 0 ..< MAX_FRAMES_IN_FLIGHT {
			vk.DestroyFence(e.gpu_context.device, e.in_flight_fences[f], nil)
			vk.DestroySemaphore(e.gpu_context.device, e.render_finished_semaphores[f], nil)
			vk.DestroySemaphore(e.gpu_context.device, e.image_available_semaphores[f], nil)
			for l in 0 ..< MAX_LANES {
				vk.DestroyCommandPool(e.gpu_context.device, e.command_pools[f][l], nil)
			}
		}
		vk.DestroyPipeline(e.gpu_context.device, e.graphics_pipeline, nil)
		vk.DestroyPipelineLayout(e.gpu_context.device, e.pipeline_layout, nil)
		vk.DestroyShaderModule(e.gpu_context.device, e.frag_module, nil)
		vk.DestroyShaderModule(e.gpu_context.device, e.vert_module, nil)

		destroy_swapchain_context(e.gpu_context.device, &e.swapchain_context)
		swapchain_memory_reset(e.swapchain_allocator)

		vk.DestroyDevice(e.gpu_context.device, nil)
	}

	if e.instance != nil {
		vk.DestroySurfaceKHR(e.instance, e.surface, nil)
		vk.DestroyInstance(e.instance, nil)
	}
	if e.window != nil {
		glfw.DestroyWindow(e.window)
	}

	glfw.Terminate()
}

// -----------------------------------------------------------------------
// Game lifecycle
// -----------------------------------------------------------------------

init_game :: proc(e: ^Engine) -> bool {
	e.engine_api = make_engine_api()

	e.game_module = Game_Module {
		dll_source_path = game_library_source_path(),
		dll_loaded_path = game_library_loaded_path(),
	}

	if !load_game_module(&e.game_module) {
		log_error("Failed to load game module")
		return false
	}

	game_memory_size := e.game_module.api.get_memory_size()
	if game_memory_size <= 0 {
		log_error("Game returned invalid memory size")
		return false
	}

	e.game_memory = make([]byte, game_memory_size, context.allocator)
	e.game_module.api.load(&e.engine_api, raw_data(e.game_memory), len(e.game_memory))
	return true
}

cleanup_game :: proc(e: ^Engine) {
	if e.game_module.is_loaded && e.game_module.api.unload != nil {
		e.game_module.api.unload(&e.engine_api, raw_data(e.game_memory), len(e.game_memory))
	}
	unload_game_module(&e.game_module)
	if len(e.game_memory) > 0 {
		delete(e.game_memory, context.allocator)
	}
}

// -----------------------------------------------------------------------
// Main loop
// -----------------------------------------------------------------------

run_main_loop :: proc(e: ^Engine) {
	for {
		// ----------------------------------------------------------------
		// Phase 1: Go wide — all lanes
		// Future: parallel entity update, SSBO packing across lanes
		// ----------------------------------------------------------------

		lane_sync()

		// ----------------------------------------------------------------
		// Phase 2: Go narrow — lane 0 only
		// ----------------------------------------------------------------
		if lane_idx() == 0 {
			free_all(context.temp_allocator)
			clear(&e.frame_commands.quads)
			glfw.PollEvents()

			if glfw.WindowShouldClose(e.window) {
				e.quit = true
				lane_sync()
				break
			}

			now := f32(glfw.GetTime())
			dt := now - e.prev_time
			if dt < 0 {
				dt = 0
			}
			e.prev_time = now

			app_callback_context = App_Callback_Context {
				commands = &e.frame_commands,
				window   = e.window,
				dt       = dt,
			}

			// Hot-reload check
			if game_module_changed(&e.game_module) {
				staged_game_dll, ok_stage := os.read_entire_file(
					e.game_module.dll_source_path,
					context.temp_allocator,
				)
				if ok_stage {
					vk.DeviceWaitIdle(e.gpu_context.device)
					e.game_module.api.unload(
						&e.engine_api,
						raw_data(e.game_memory),
						len(e.game_memory),
					)
					unload_game_module(&e.game_module)

					if !load_game_module_from_bytes(&e.game_module, staged_game_dll) {
						delete(staged_game_dll, context.temp_allocator)
						log_warn("Game reload failed, keeping previous binary unloaded")
					} else {
						delete(staged_game_dll, context.temp_allocator)
						if e.game_module.api.get_memory_size() != len(e.game_memory) {
							log_warnf(
								"Game memory size changed from %d to %d; preserving old block",
								len(e.game_memory),
								e.game_module.api.get_memory_size(),
							)
						}
						e.game_module.api.reload(
							&e.engine_api,
							raw_data(e.game_memory),
							len(e.game_memory),
						)
					}
				}
			}

			if e.game_module.is_loaded {
				e.game_module.api.update(
					&e.engine_api,
					raw_data(e.game_memory),
					len(e.game_memory),
				)
			}

			// Copy quad data to current frame SSBO
			quad_count := min(len(e.frame_commands.quads), MAX_QUADS)
			if quad_count > 0 {
				mem.copy(
					e.quad_ssbos[e.current_frame].mapped,
					raw_data(e.frame_commands.quads),
					quad_count * size_of(Quad_Command),
				)
			}

			// Wait for the previous frame to finish
			wait_result := vk.WaitForFences(
				e.gpu_context.device,
				1,
				&e.in_flight_fences[e.current_frame],
				true,
				~u64(0),
			)
			#partial switch wait_result {
			case .SUCCESS:
			case .ERROR_DEVICE_LOST:
				log_error("Device lost while waiting for fence")
				e.quit = true
				lane_sync()
				return
			case .TIMEOUT:
				lane_sync()
				continue
			case:
				log_errorf("WaitForFences failed: %v", wait_result)
				e.quit = true
				lane_sync()
				return
			}

			// Acquire the next swapchain image
			image_index: u32
			acquire_result := vk.AcquireNextImageKHR(
				e.gpu_context.device,
				e.swapchain_context.handle,
				~u64(0),
				e.image_available_semaphores[e.current_frame],
				vk.Fence(0),
				&image_index,
			)
			#partial switch acquire_result {
			case .SUCCESS:
			case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR:
				if !recreate_swapchain_and_pipeline(
					e.window,
					e.gpu_context.device,
					e.physical_device,
					e.surface,
					e.queue_family_indices,
					e.swapchain_allocator,
					&e.swapchain_context,
					e.shader_stages[:],
					&e.pipeline_layout,
					&e.graphics_pipeline,
					e.descriptor_layout,
				) {
					if !glfw.WindowShouldClose(e.window) {
						log_error("Failed to recreate swapchain/pipeline after acquire")
						e.quit = true
					}
				}
				lane_sync()
				continue
			case .ERROR_DEVICE_LOST:
				log_error("Device lost in AcquireNextImageKHR")
				e.quit = true
				lane_sync()
				return
			case:
				log_errorf("AcquireNextImageKHR failed: %v", acquire_result)
				e.quit = true
				lane_sync()
				return
			}

			if vk.ResetCommandBuffer(e.cmds[e.current_frame][0], {}) != .SUCCESS {
				log_error("Failed to reset command buffer")
				e.quit = true
				lane_sync()
				return
			}

			if !record_command_buffer(
				e.cmds[e.current_frame][0],
				e.swapchain_context.images[image_index],
				e.swapchain_context.image_views[image_index],
				e.swapchain_context.extent,
				e.graphics_pipeline,
				e.pipeline_layout,
				e.descriptor_sets[e.current_frame],
				e.frame_commands.clear_color,
				quad_count,
			) {
				log_error("Failed to record command buffer")
				e.quit = true
				lane_sync()
				return
			}

			if vk.ResetFences(
				   e.gpu_context.device,
				   1,
				   &e.in_flight_fences[e.current_frame],
			   ) !=
			   .SUCCESS {
				log_error("ResetFences failed")
				e.quit = true
				lane_sync()
				return
			}

			wait_stages := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
			render_finished_semaphore := e.render_finished_semaphores[e.current_frame]
			submit_info := vk.SubmitInfo {
				sType                = .SUBMIT_INFO,
				waitSemaphoreCount   = 1,
				pWaitSemaphores      = &e.image_available_semaphores[e.current_frame],
				pWaitDstStageMask    = &wait_stages,
				commandBufferCount   = 1,
				pCommandBuffers      = &e.cmds[e.current_frame][0],
				signalSemaphoreCount = 1,
				pSignalSemaphores    = &render_finished_semaphore,
			}
			if vk.QueueSubmit(
				   e.gpu_context.graphics_queue,
				   1,
				   &submit_info,
				   e.in_flight_fences[e.current_frame],
			   ) !=
			   .SUCCESS {
				log_error("Failed to submit graphics queue")
				e.quit = true
				lane_sync()
				return
			}

			present_info := vk.PresentInfoKHR {
				sType              = .PRESENT_INFO_KHR,
				waitSemaphoreCount = 1,
				pWaitSemaphores    = &render_finished_semaphore,
				swapchainCount     = 1,
				pSwapchains        = &e.swapchain_context.handle,
				pImageIndices      = &image_index,
			}
			present_result := vk.QueuePresentKHR(e.gpu_context.present_queue, &present_info)
			#partial switch present_result {
			case .SUCCESS:
			case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR:
				if !recreate_swapchain_and_pipeline(
					e.window,
					e.gpu_context.device,
					e.physical_device,
					e.surface,
					e.queue_family_indices,
					e.swapchain_allocator,
					&e.swapchain_context,
					e.shader_stages[:],
					&e.pipeline_layout,
					&e.graphics_pipeline,
					e.descriptor_layout,
				) {
					if !glfw.WindowShouldClose(e.window) {
						log_error("Failed to recreate swapchain/pipeline after present")
						e.quit = true
					}
				}
			case .ERROR_DEVICE_LOST:
				log_error("Device lost in QueuePresentKHR")
				e.quit = true
				lane_sync()
				return
			case:
				log_errorf("QueuePresentKHR failed: %v", present_result)
				e.quit = true
				lane_sync()
				return
			}

			e.current_frame = (e.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
		} // end lane 0

		lane_sync()

		if e.quit {
			break
		}
	}
}

// -----------------------------------------------------------------------
// Entry point
// -----------------------------------------------------------------------

main :: proc() {
	context.allocator, context.temp_allocator = memory_init()

	e: Engine

	if !init(&e) {
		cleanup(&e)
		return
	}
	defer cleanup(&e)

	if !init_game(&e) {
		cleanup_game(&e)
		return
	}
	defer cleanup_game(&e)

	e.prev_time = f32(glfw.GetTime())

	lane_init(MAX_LANES)

	threads: [MAX_LANES]^thread.Thread
	for i in 1 ..< MAX_LANES {
		t := thread.create(engine_thread_proc)
		t.data = &e
		t.user_index = i
		threads[i] = t
		thread.start(t)
	}

	_lane_idx = 0
	run_main_loop(&e)

	for i in 1 ..< MAX_LANES {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
}
