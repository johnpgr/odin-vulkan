package engine

import "core:mem"
import "core:os"
import "core:fmt"
import glfw "vendor:glfw"
import vk "vendor:vulkan"

when ODIN_OS == .Windows {
	foreign import vulkan "system:vulkan-1.lib"
} else when ODIN_OS == .Linux {
	foreign import vulkan "system:vulkan"
} else when ODIN_OS == .Darwin {
	foreign import vulkan "system:vulkan"
}

@(default_calling_convention = "system")
foreign vulkan {
	@(link_name = "vkGetInstanceProcAddr")
	vkGetInstanceProcAddr :: proc(instance: vk.Instance, pName: cstring) -> vk.ProcVoidFunction ---
}

// -----------------------------------------------------------------------
// Queue families
// -----------------------------------------------------------------------

QueueFamilyIndices :: struct {
	graphics_family: u32,
	present_family:  u32,
}

find_queue_families :: proc(
	device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
) -> (
	QueueFamilyIndices,
	bool,
) {
	// First we get the count
	queue_family_count: u32 = 0
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
	if queue_family_count == 0 {
		return {}, false
	}

	// Make the empty array with the count
	queue_families := make(
		[]vk.QueueFamilyProperties,
		int(queue_family_count),
		context.temp_allocator,
	)
	defer delete(queue_families, context.temp_allocator)

	// Then we pass the array ptr to populate it..
	vk.GetPhysicalDeviceQueueFamilyProperties(
		device,
		&queue_family_count,
		raw_data(queue_families),
	)

	families := QueueFamilyIndices{}
	found_gfx: b32 = false
	found_present: b32 = false

	// Then we loop it to get the families idxs
	for i in 0 ..< int(queue_family_count) {
		q := queue_families[i]
		if q.queueCount > 0 {
			if .GRAPHICS in q.queueFlags {
				families.graphics_family = u32(i)
				found_gfx = true
			}

			if !found_present {
				vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), surface, &found_present)
				if found_present {
					families.present_family = u32(i)
				}
			}
		}
	}

	if !found_gfx || !found_present {
		return {}, false
	}

	return families, true
}

// -----------------------------------------------------------------------
// Device helpers
// -----------------------------------------------------------------------

device_extension_available :: proc(device: vk.PhysicalDevice, name: cstring) -> bool {
	count: u32 = 0
	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) != .SUCCESS || count == 0 {
		return false
	}

	props := make([]vk.ExtensionProperties, int(count), context.temp_allocator)
	defer delete(props, context.temp_allocator)

	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(props)) != .SUCCESS {
		return false
	}

	target := string(name)
	for i in 0 ..< int(count) {
		ext_name := string(cast(cstring)&props[i].extensionName[0])
		if ext_name == target {
			return true
		}
	}
	return false
}

GpuContext :: struct {
	device:                vk.Device,
	graphics_queue:        vk.Queue,
	graphics_family_index: u32,
	present_queue:         vk.Queue,
	present_family_index:  u32,
}

create_gpu_context :: proc(
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
) -> (
	GpuContext,
	bool,
) {
	queue_families, ok := find_queue_families(physical_device, surface)
	if !ok {
		return {}, false
	}

	queue_priority: f32 = 1.0
	queue_create_infos: [2]vk.DeviceQueueCreateInfo
	queue_create_info_count: u32 = 1

	queue_create_infos[0] = vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = queue_families.graphics_family,
		queueCount       = 1,
		pQueuePriorities = &queue_priority,
	}

	if queue_families.present_family != queue_families.graphics_family {
		queue_create_infos[1] = vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = queue_families.present_family,
			queueCount       = 1,
			pQueuePriorities = &queue_priority,
		}
		queue_create_info_count = 2
	}

	// Specify the device extensions we need (swapchain is essencial for rendering)
	device_extensions := make([dynamic]cstring, context.temp_allocator)

	if device_extension_available(physical_device, vk.KHR_SWAPCHAIN_EXTENSION_NAME) {
		append(&device_extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
	}

	if device_extension_available(physical_device, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME) {
		append(&device_extensions, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME)
	}

	// Specify which physical device features we'll use
	// For a basic triangle, we leave everything at defaults (disabled)
	device_features := vk.PhysicalDeviceFeatures{}

	// For Vulkan 1.3 features like dynamic rendering, chain a features struct
	dynamic_rendering_feature := vk.PhysicalDeviceDynamicRenderingFeatures {
		sType            = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
		dynamicRendering = true,
	}

	synchronization2_feature := vk.PhysicalDeviceSynchronization2Features {
		sType            = .PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
		pNext            = &dynamic_rendering_feature,
		synchronization2 = true,
	}

	features2 := vk.PhysicalDeviceFeatures2 {
		sType    = .PHYSICAL_DEVICE_FEATURES_2,
		pNext    = &synchronization2_feature,
		features = device_features,
	}

	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features2,
		queueCreateInfoCount    = queue_create_info_count,
		pQueueCreateInfos       = &queue_create_infos[0],
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions[:]),
	}

	device: vk.Device

	if vk.CreateDevice(physical_device, &create_info, nil, &device) != .SUCCESS {
		return {}, false
	}

	vk.load_proc_addresses_device(device)

	graphics_queue, present_queue: vk.Queue
	vk.GetDeviceQueue(device, queue_families.graphics_family, 0, &graphics_queue)
	vk.GetDeviceQueue(device, queue_families.present_family, 0, &present_queue)

	gpu_context := GpuContext {
		device                = device,
		graphics_queue        = graphics_queue,
		graphics_family_index = queue_families.graphics_family,
		present_queue         = present_queue,
		present_family_index  = queue_families.present_family,
	}

	return gpu_context, true
}

has_graphics_queue_family :: proc(device: vk.PhysicalDevice) -> bool {
	queue_family_count: u32 = 0
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
	if queue_family_count == 0 {
		return false
	}

	queue_families := make(
		[]vk.QueueFamilyProperties,
		int(queue_family_count),
		context.temp_allocator,
	)
	defer delete(queue_families, context.temp_allocator)

	vk.GetPhysicalDeviceQueueFamilyProperties(
		device,
		&queue_family_count,
		raw_data(queue_families),
	)

	for q in queue_families {
		if q.queueCount > 0 && (.GRAPHICS in q.queueFlags) {
			return true
		}
	}

	return false
}

pick_physical_device :: proc(
	instance: vk.Instance,
) -> (
	vk.PhysicalDevice,
	vk.PhysicalDeviceProperties,
	bool,
) {
	device_count: u32 = 0
	if vk.EnumeratePhysicalDevices(instance, &device_count, nil) != .SUCCESS || device_count == 0 {
		return {}, {}, false
	}

	devices := make([]vk.PhysicalDevice, int(device_count), context.temp_allocator)
	defer delete(devices, context.temp_allocator)

	if vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices)) != .SUCCESS {
		return {}, {}, false
	}

	device: vk.PhysicalDevice = nil
	props: vk.PhysicalDeviceProperties

	for d in devices {
		vk.GetPhysicalDeviceProperties(d, &props)
		if props.deviceType == .DISCRETE_GPU {
			device = d
			break
		}
	}

	if device == nil {
		return {}, {}, false
	}

	return device, props, true
}

has_extension_name :: proc(exts: []cstring, target: cstring) -> bool {
	target_name := string(target)
	for ext in exts {
		if ext != nil && string(ext) == target_name {
			return true
		}
	}
	return false
}

instance_extension_available :: proc(name: cstring) -> bool {
	count: u32 = 0
	if vk.EnumerateInstanceExtensionProperties(nil, &count, nil) != .SUCCESS || count == 0 {
		return false
	}

	props := make([]vk.ExtensionProperties, int(count), context.temp_allocator)
	defer delete(props, context.temp_allocator)

	if vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(props)) != .SUCCESS {
		return false
	}

	name_str := string(name)
	for i in 0 ..< int(count) {
		ext_name := string(cast(cstring)&props[i].extensionName[0])
		if ext_name == name_str {
			return true
		}
	}

	return false
}

// -----------------------------------------------------------------------
// Swapchain
// -----------------------------------------------------------------------

SwapchainContext :: struct {
	handle:       vk.SwapchainKHR,
	images:       []vk.Image,
	image_views:  []vk.ImageView,
	image_format: vk.Format,
	extent:       vk.Extent2D,
}

surface_format_supports_usage :: proc(
	physical_device: vk.PhysicalDevice,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
) -> bool {
	props: vk.ImageFormatProperties
	return vk.GetPhysicalDeviceImageFormatProperties(
		physical_device,
		format,
		.D2,
		.OPTIMAL,
		usage,
		{},
		&props,
	) == .SUCCESS
}

// -----------------------------------------------------------------------
// Rendering data types
// -----------------------------------------------------------------------

Quad_Command :: struct {
	rect:  [4]f32,
	color: [4]f32,
}

Frame_Commands :: struct {
	clear_color: [4]f32,
	quads:       [dynamic]Quad_Command,
}

// -----------------------------------------------------------------------
// Swapchain creation / destruction
// -----------------------------------------------------------------------

// Query the surface capabilities to decide the
// image format, resolution, and present mode
// then create the swap chain.
create_swapchain_context :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	indices: QueueFamilyIndices,
	swapchain_allocator: mem.Allocator,
) -> (
	SwapchainContext,
	bool,
) {
	// Get the capabilities
	capabilities: vk.SurfaceCapabilitiesKHR
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &capabilities) !=
	   .SUCCESS {
		return {}, false
	}

	// Get the formats
	format_count: u32 = 0
	if vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, nil) !=
	   .SUCCESS {
		return {}, false
	}

	formats := make([]vk.SurfaceFormatKHR, int(format_count), context.temp_allocator)
	defer delete(formats, context.temp_allocator)

	if vk.GetPhysicalDeviceSurfaceFormatsKHR(
		   physical_device,
		   surface,
		   &format_count,
		   raw_data(formats),
	   ) !=
	   .SUCCESS {
		return {}, false
	}

	// Get the present modes
	present_mode_count: u32 = 0
	if vk.GetPhysicalDeviceSurfacePresentModesKHR(
		   physical_device,
		   surface,
		   &present_mode_count,
		   nil,
	   ) !=
	   .SUCCESS {
		return {}, false
	}

	present_modes := make([]vk.PresentModeKHR, int(present_mode_count), context.temp_allocator)
	defer delete(present_modes, context.temp_allocator)

	if vk.GetPhysicalDeviceSurfacePresentModesKHR(
		   physical_device,
		   surface,
		   &present_mode_count,
		   raw_data(present_modes),
	   ) !=
	   .SUCCESS {
		return {}, false
	}

	image_usage := vk.ImageUsageFlags{.COLOR_ATTACHMENT}

	validation_usage := image_usage
	if .TRANSFER_SRC in capabilities.supportedUsageFlags {
		validation_usage += {.TRANSFER_SRC}
	}
	if .STORAGE in capabilities.supportedUsageFlags {
		validation_usage += {.STORAGE}
	}

	// Choose a surface format, preferring SRGB, but only when image usage is supported.
	chosen_format := formats[0] // fallback
	found_compatible := false

	for f in formats {
		if f.format == .B8G8R8A8_SRGB &&
		   f.colorSpace == .SRGB_NONLINEAR &&
		   surface_format_supports_usage(physical_device, f.format, validation_usage) {
			chosen_format = f
			found_compatible = true
			break
		}
	}

	if !found_compatible {
		for f in formats {
			if f.format == .B8G8R8A8_UNORM &&
			   f.colorSpace == .SRGB_NONLINEAR &&
			   surface_format_supports_usage(physical_device, f.format, validation_usage) {
				chosen_format = f
				found_compatible = true
				break
			}
		}
	}

	if !found_compatible {
		for f in formats {
			if surface_format_supports_usage(physical_device, f.format, validation_usage) {
				chosen_format = f
				found_compatible = true
				break
			}
		}
	}

	// Choose present mode - prefer mailbox (triple buffering) if available
	chosen_present_mode: vk.PresentModeKHR = .FIFO
	for p in present_modes {
		if p == .MAILBOX {
			chosen_present_mode = p
			break
		}
	}

	// Choose extent (resolution)
	swap_extent := capabilities.currentExtent

	// Request one more image than the minimum for smooth operation
	image_count := capabilities.minImageCount + 1
	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	swapchain_create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		// Target window surface the swapchain presents to.
		surface          = surface,
		// Number of images to keep in the swapchain.
		minImageCount    = image_count,
		// Pixel format of swapchain images.
		imageFormat      = chosen_format.format,
		// Color space used for presentation output.
		imageColorSpace  = chosen_format.colorSpace,
		// Resolution of each swapchain image.
		imageExtent      = swap_extent,
		// Layers per image (1 for regular 2D rendering).
		imageArrayLayers = 1,
		// Intended usage of swapchain images.
		imageUsage       = image_usage,
		// Queue ownership mode for image access.
		imageSharingMode = .EXCLUSIVE,
		// Transform applied when presenting (e.g., rotation).
		preTransform     = capabilities.currentTransform,
		// How alpha is blended with the window system.
		compositeAlpha   = {.OPAQUE},
		// Presentation pacing strategy (vsync/latency behavior).
		presentMode      = chosen_present_mode,
		// Ignore rendering to pixels hidden by other windows.
		clipped          = true,
	}

	if indices.graphics_family != indices.present_family {
		family_indices := []u32{indices.graphics_family, indices.present_family}
		swapchain_create_info.imageSharingMode = .CONCURRENT
		swapchain_create_info.queueFamilyIndexCount = 2
		swapchain_create_info.pQueueFamilyIndices = raw_data(family_indices)
	}

	swapchain: vk.SwapchainKHR
	if vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &swapchain) != .SUCCESS {
		return {}, false
	}

	swapchain_image_count: u32 = 0
	if vk.GetSwapchainImagesKHR(device, swapchain, &swapchain_image_count, nil) != .SUCCESS {
		vk.DestroySwapchainKHR(device, swapchain, nil)
		return {}, false
	}

	swapchain_images := make([]vk.Image, int(swapchain_image_count), swapchain_allocator)
	if vk.GetSwapchainImagesKHR(
		   device,
		   swapchain,
		   &swapchain_image_count,
		   raw_data(swapchain_images),
	   ) !=
	   .SUCCESS {
		vk.DestroySwapchainKHR(device, swapchain, nil)
		return {}, false
	}

	swapchain_image_views := make([]vk.ImageView, len(swapchain_images), swapchain_allocator)
	created_image_views := 0

	for image in swapchain_images {
		view_create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = chosen_format.format,
			components = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}

		image_view: vk.ImageView
		if vk.CreateImageView(device, &view_create_info, nil, &image_view) != .SUCCESS {
			for created_index in 0 ..< created_image_views {
				vk.DestroyImageView(device, swapchain_image_views[created_index], nil)
			}
			vk.DestroySwapchainKHR(device, swapchain, nil)
			return {}, false
		}
		swapchain_image_views[created_image_views] = image_view
		created_image_views += 1
	}

	swapchain_context := SwapchainContext {
		handle       = swapchain,
		images       = swapchain_images,
		image_views  = swapchain_image_views,
		image_format = chosen_format.format,
		extent       = swap_extent,
	}
	return swapchain_context, true
}

destroy_swapchain_context :: proc(device: vk.Device, swapchain_context: ^SwapchainContext) {
	if len(swapchain_context.image_views) > 0 {
		for image_view in swapchain_context.image_views {
			vk.DestroyImageView(device, image_view, nil)
		}
	}
	if len(swapchain_context.images) > 0 {
		vk.DestroySwapchainKHR(device, swapchain_context.handle, nil)
	}
	swapchain_context^ = {}
}

// -----------------------------------------------------------------------
// Semaphores & swapchain recreation
// -----------------------------------------------------------------------

create_render_finished_semaphores :: proc(
	device: vk.Device,
	count: int,
) -> (
	[]vk.Semaphore,
	bool,
) {
	semaphore_create_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	semaphores := make([]vk.Semaphore, count, context.allocator)
	for i in 0 ..< count {
		if vk.CreateSemaphore(device, &semaphore_create_info, nil, &semaphores[i]) != .SUCCESS {
			for destroy_i in 0 ..< i {
				vk.DestroySemaphore(device, semaphores[destroy_i], nil)
			}
			delete(semaphores, context.allocator)
			return nil, false
		}
	}

	return semaphores, true
}

destroy_render_finished_semaphores :: proc(
	device: vk.Device,
	semaphores: ^[]vk.Semaphore,
) {
	for semaphore in semaphores^ {
		vk.DestroySemaphore(device, semaphore, nil)
	}

	if len(semaphores^) > 0 {
		delete(semaphores^, context.allocator)
	}
	semaphores^ = nil
}

recreate_swapchain :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	indices: QueueFamilyIndices,
	swapchain_allocator: mem.Allocator,
	swapchain_context: ^SwapchainContext,
) -> bool {
	vk.DeviceWaitIdle(device)
	destroy_swapchain_context(device, swapchain_context)
	swapchain_memory_reset(swapchain_allocator)

	new_swapchain_context, ok_swapchain := create_swapchain_context(
		device,
		physical_device,
		surface,
		indices,
		swapchain_allocator,
	)
	if !ok_swapchain {
		return false
	}

	swapchain_context^ = new_swapchain_context
	return true
}

wait_for_non_zero_framebuffer :: proc(window: glfw.WindowHandle) -> bool {
	for {
		width, height := glfw.GetFramebufferSize(window)
		if width > 0 && height > 0 {
			return true
		}

		if glfw.WindowShouldClose(window) {
			return false
		}

		glfw.WaitEvents()
	}
}

// -----------------------------------------------------------------------
// Command recording
// -----------------------------------------------------------------------

record_command_buffer :: proc(
	cmd: vk.CommandBuffer,
	swapchain_image: vk.Image,
	image_view: vk.ImageView,
	extent: vk.Extent2D,
	pipeline: vk.Pipeline,
	layout: vk.PipelineLayout,
	commands: ^Frame_Commands,
) -> bool {
	cmd_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}

	if vk.BeginCommandBuffer(cmd, &cmd_begin_info) != .SUCCESS {
		return false
	}

	// Transition swapchain image to color attachment optimal
	begin_barrier := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.TOP_OF_PIPE},
		srcAccessMask    = {},
		dstStageMask     = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask    = {.COLOR_ATTACHMENT_WRITE},
		oldLayout        = .UNDEFINED,
		newLayout        = .COLOR_ATTACHMENT_OPTIMAL,
		image            = swapchain_image,
		subresourceRange = {{.COLOR}, 0, 1, 0, 1},
	}

	dependency_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &begin_barrier,
	}

	vk.CmdPipelineBarrier2(cmd, &dependency_info)

	clear := commands.clear_color
	clear_value := vk.ClearValue {
		color = vk.ClearColorValue{float32 = {clear[0], clear[1], clear[2], clear[3]}},
	}

	// Define the color attachment for dynamic rendering
	color_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = image_view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = clear_value,
	}

	// Begin dynamic rendering
	render_info := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = {{0, 0}, extent},
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment,
	}

	vk.CmdBeginRendering(cmd, &render_info)

	// Bind pipeline and set dynamic state
	vk.CmdBindPipeline(cmd, .GRAPHICS, pipeline)

	viewports := vk.Viewport{0.0, 0.0, f32(extent.width), f32(extent.height), 0.0, 1.0}
	vk.CmdSetViewport(cmd, 0, 1, &viewports)

	rect := vk.Rect2D{{0, 0}, extent}
	vk.CmdSetScissor(cmd, 0, 1, &rect)

	for i in 0 ..< len(commands.quads) {
		quad := &commands.quads[i]
		vk.CmdPushConstants(
			cmd,
			layout,
			{.VERTEX, .FRAGMENT},
			0,
			u32(size_of(Quad_Command)),
			quad,
		)
		vk.CmdDraw(cmd, 6, 1, 0, 0)
	}

	vk.CmdEndRendering(cmd)

	// Transition swapchain image to present layout
	end_barrier := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask    = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask     = {.BOTTOM_OF_PIPE},
		dstAccessMask    = {},
		oldLayout        = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout        = .PRESENT_SRC_KHR,
		image            = swapchain_image,
		subresourceRange = {{.COLOR}, 0, 1, 0, 1},
	}

	end_dependency_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &end_barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &end_dependency_info)

	if vk.EndCommandBuffer(cmd) != .SUCCESS {
		return false
	}

	return true
}

// -----------------------------------------------------------------------
// Shaders & pipeline
// -----------------------------------------------------------------------

has_suffix :: proc(value: string, suffix: string) -> bool {
	if len(value) < len(suffix) {
		return false
	}

	return value[len(value)-len(suffix):] == suffix
}

load_shader :: proc(
	device: vk.Device,
	shader_name: string,
) -> (
	vk.ShaderModule,
	vk.PipelineShaderStageCreateInfo,
	bool,
) {
	shader_stage := vk.ShaderStageFlags{}
	if has_suffix(shader_name, ".vert") {
		shader_stage = {.VERTEX}
	} else if has_suffix(shader_name, ".frag") {
		shader_stage = {.FRAGMENT}
	} else {
		log_errorf("Unsupported shader stage for %s", shader_name)
		return {}, {}, false
	}

	shader_path := fmt.tprintf("engine/shaders/%s.spv", shader_name)
	shader_code, ok_shader := os.read_entire_file(shader_path, context.temp_allocator)
	if !ok_shader {
		log_errorf("Failed to load shader from disk: %s", shader_path)
		return {}, {}, false
	}
	defer delete(shader_code, context.temp_allocator)

	shader_module_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(shader_code),
		pCode    = cast([^]u32)raw_data(shader_code),
	}

	shader_module: vk.ShaderModule
	if vk.CreateShaderModule(device, &shader_module_info, nil, &shader_module) != .SUCCESS {
		log_errorf("Failed to create shader module: %s", shader_path)
		return {}, {}, false
	}

	shader_stage_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = shader_stage,
		module = shader_module,
		pName  = "main",
	}

	return shader_module, shader_stage_info, true
}

create_graphics_pipeline :: proc(
	device: vk.Device,
	image_format: vk.Format,
	shader_stages: []vk.PipelineShaderStageCreateInfo,
) -> (
	vk.PipelineLayout,
	vk.Pipeline,
	bool,
) {
	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	input_asssembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(&dynamic_states),
	}

	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable        = false,
		rasterizerDiscardEnable = false,
		polygonMode             = .FILL,
		cullMode                = {.BACK},
		frontFace               = .CLOCKWISE,
		depthBiasEnable         = false,
		lineWidth               = 1.0,
	}

	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
		sampleShadingEnable  = false,
	}

	colorblend_attachment := vk.PipelineColorBlendAttachmentState {
		blendEnable    = false,
		colorWriteMask = {.R, .G, .B, .A},
	}

	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		attachmentCount = 1,
		pAttachments    = &colorblend_attachment,
	}

	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		offset     = 0,
		size       = u32(size_of(Quad_Command)),
	}

	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_constant_range,
	}

	pipeline_layout: vk.PipelineLayout
	if vk.CreatePipelineLayout(device, &pipeline_layout_info, nil, &pipeline_layout) != .SUCCESS {
		return {}, {}, false
	}

	color_attachment_format := image_format
	rendering_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &color_attachment_format,
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering_info,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_asssembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state,
		layout              = pipeline_layout,
	}

	graphics_pipeline: vk.Pipeline
	if vk.CreateGraphicsPipelines(
		   device,
		   vk.PipelineCache(0),
		   1,
		   &pipeline_info,
		   nil,
		   &graphics_pipeline,
	   ) !=
	   .SUCCESS {
		vk.DestroyPipelineLayout(device, pipeline_layout, nil)
		return {}, {}, false
	}

	return pipeline_layout, graphics_pipeline, true
}

recreate_swapchain_and_pipeline :: proc(
	window: glfw.WindowHandle,
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	indices: QueueFamilyIndices,
	swapchain_allocator: mem.Allocator,
	swapchain_context: ^SwapchainContext,
	shader_stages: []vk.PipelineShaderStageCreateInfo,
	pipeline_layout: ^vk.PipelineLayout,
	graphics_pipeline: ^vk.Pipeline,
	render_finished_semaphores: ^[]vk.Semaphore,
) -> bool {
	if !wait_for_non_zero_framebuffer(window) {
		return false
	}

	if !recreate_swapchain(
		device,
		physical_device,
		surface,
		indices,
		swapchain_allocator,
		swapchain_context,
	) {
		return false
	}

	new_pipeline_layout, new_graphics_pipeline, ok_pipeline := create_graphics_pipeline(
		device,
		swapchain_context.image_format,
		shader_stages,
	)
	if !ok_pipeline {
		return false
	}

	vk.DestroyPipeline(device, graphics_pipeline^, nil)
	vk.DestroyPipelineLayout(device, pipeline_layout^, nil)

	graphics_pipeline^ = new_graphics_pipeline
	pipeline_layout^ = new_pipeline_layout

	destroy_render_finished_semaphores(device, render_finished_semaphores)

	new_render_finished_semaphores, ok_render_finished_semaphores :=
		create_render_finished_semaphores(device, len(swapchain_context.images))
	if !ok_render_finished_semaphores {
		return false
	}
	render_finished_semaphores^ = new_render_finished_semaphores

	return true
}
