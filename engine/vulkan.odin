package engine

import "core:fmt"
import "core:mem"
import "core:os"
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

MAX_QUADS :: 4096
MAX_MESHES :: 64

Cmd_Pipeline_Barrier2_Proc :: #type type_of(vk.CmdPipelineBarrier2)
Cmd_Begin_Rendering_Proc :: #type type_of(vk.CmdBeginRendering)
Cmd_End_Rendering_Proc :: #type type_of(vk.CmdEndRendering)

@(private = "package")
vkCmdPipelineBarrier2: Cmd_Pipeline_Barrier2_Proc

@(private)
vkCmdBeginRendering: Cmd_Begin_Rendering_Proc

@(private)
vkCmdEndRendering: Cmd_End_Rendering_Proc

// -----------------------------------------------------------------------
// GPU buffer helpers
// -----------------------------------------------------------------------

Mapped_Buffer :: struct {
	handle: vk.Buffer,
	memory: vk.DeviceMemory,
	mapped: rawptr,
	size:   vk.DeviceSize,
}

Gpu_Buffer :: struct {
	handle: vk.Buffer,
	memory: vk.DeviceMemory,
}

find_memory_type :: proc(
	physical_device: vk.PhysicalDevice,
	type_filter: u32,
	properties: vk.MemoryPropertyFlags,
) -> (
	u32,
	bool,
) {
	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(physical_device, &mem_props)
	for i in 0 ..< mem_props.memoryTypeCount {
		if (type_filter & (1 << i)) != 0 &&
		   (mem_props.memoryTypes[i].propertyFlags & properties) == properties {
			return i, true
		}
	}
	return 0, false
}

create_mapped_buffer :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
) -> (
	Mapped_Buffer,
	bool,
) {
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	buffer: vk.Buffer
	if vk.CreateBuffer(device, &buffer_info, nil, &buffer) != .SUCCESS {
		return {}, false
	}

	mem_reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, buffer, &mem_reqs)

	mem_type, ok := find_memory_type(
		physical_device,
		mem_reqs.memoryTypeBits,
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	if !ok {
		vk.DestroyBuffer(device, buffer, nil)
		return {}, false
	}

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_type,
	}
	memory: vk.DeviceMemory
	if vk.AllocateMemory(device, &alloc_info, nil, &memory) != .SUCCESS {
		vk.DestroyBuffer(device, buffer, nil)
		return {}, false
	}

	if vk.BindBufferMemory(device, buffer, memory, 0) != .SUCCESS {
		vk.FreeMemory(device, memory, nil)
		vk.DestroyBuffer(device, buffer, nil)
		return {}, false
	}

	mapped: rawptr
	if vk.MapMemory(device, memory, 0, size, {}, &mapped) != .SUCCESS {
		vk.FreeMemory(device, memory, nil)
		vk.DestroyBuffer(device, buffer, nil)
		return {}, false
	}

	return Mapped_Buffer{handle = buffer, memory = memory, mapped = mapped, size = size}, true
}

destroy_mapped_buffer :: proc(device: vk.Device, buf: ^Mapped_Buffer) {
	if buf.mapped != nil {
		vk.UnmapMemory(device, buf.memory)
	}
	if buf.handle != 0 {
		vk.DestroyBuffer(device, buf.handle, nil)
	}
	if buf.memory != 0 {
		vk.FreeMemory(device, buf.memory, nil)
	}
	buf^ = {}
}

destroy_gpu_buffer :: proc(device: vk.Device, buf: ^Gpu_Buffer) {
	if buf.handle != 0 {
		vk.DestroyBuffer(device, buf.handle, nil)
	}
	if buf.memory != 0 {
		vk.FreeMemory(device, buf.memory, nil)
	}
	buf^ = {}
}

create_depth_image :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	extent: vk.Extent2D,
) -> (
	vk.Image,
	vk.ImageView,
	vk.DeviceMemory,
	bool,
) {
	image_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = .D32_SFLOAT,
		extent        = {extent.width, extent.height, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = {.DEPTH_STENCIL_ATTACHMENT},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}

	image: vk.Image
	if vk.CreateImage(device, &image_info, nil, &image) != .SUCCESS {
		return {}, {}, {}, false
	}

	mem_reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(device, image, &mem_reqs)

	mem_type, ok_mem_type := find_memory_type(
		physical_device,
		mem_reqs.memoryTypeBits,
		{.DEVICE_LOCAL},
	)
	if !ok_mem_type {
		vk.DestroyImage(device, image, nil)
		return {}, {}, {}, false
	}

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_type,
	}

	memory: vk.DeviceMemory
	if vk.AllocateMemory(device, &alloc_info, nil, &memory) != .SUCCESS {
		vk.DestroyImage(device, image, nil)
		return {}, {}, {}, false
	}

	if vk.BindImageMemory(device, image, memory, 0) != .SUCCESS {
		vk.FreeMemory(device, memory, nil)
		vk.DestroyImage(device, image, nil)
		return {}, {}, {}, false
	}

	view_info := vk.ImageViewCreateInfo {
		sType    = .IMAGE_VIEW_CREATE_INFO,
		image    = image,
		viewType = .D2,
		format   = .D32_SFLOAT,
		subresourceRange = {
			aspectMask     = {.DEPTH},
			baseMipLevel   = 0,
			levelCount     = 1,
			baseArrayLayer = 0,
			layerCount     = 1,
		},
	}

	view: vk.ImageView
	if vk.CreateImageView(device, &view_info, nil, &view) != .SUCCESS {
		vk.FreeMemory(device, memory, nil)
		vk.DestroyImage(device, image, nil)
		return {}, {}, {}, false
	}

	return image, view, memory, true
}

destroy_depth_image :: proc(
	device: vk.Device,
	image: vk.Image,
	view: vk.ImageView,
	memory: vk.DeviceMemory,
) {
	if view != 0 {
		vk.DestroyImageView(device, view, nil)
	}
	if image != 0 {
		vk.DestroyImage(device, image, nil)
	}
	if memory != 0 {
		vk.FreeMemory(device, memory, nil)
	}
}

create_device_local_buffer :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	command_pool: vk.CommandPool,
	queue: vk.Queue,
	data_ptr: rawptr,
	data_size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
) -> (
	Gpu_Buffer,
	bool,
) {
	if data_ptr == nil || data_size == 0 {
		return {}, false
	}

	staging, ok_staging := create_mapped_buffer(
		device,
		physical_device,
		data_size,
		{.TRANSFER_SRC},
	)
	if !ok_staging {
		return {}, false
	}
	defer destroy_mapped_buffer(device, &staging)

	mem.copy(staging.mapped, data_ptr, int(data_size))

	final_buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = data_size,
		usage       = usage + {.TRANSFER_DST},
		sharingMode = .EXCLUSIVE,
	}

	final_buffer: vk.Buffer
	if vk.CreateBuffer(device, &final_buffer_info, nil, &final_buffer) != .SUCCESS {
		return {}, false
	}

	final_reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, final_buffer, &final_reqs)

	final_mem_type, ok_final_mem_type := find_memory_type(
		physical_device,
		final_reqs.memoryTypeBits,
		{.DEVICE_LOCAL},
	)
	if !ok_final_mem_type {
		vk.DestroyBuffer(device, final_buffer, nil)
		return {}, false
	}

	final_alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = final_reqs.size,
		memoryTypeIndex = final_mem_type,
	}
	final_memory: vk.DeviceMemory
	if vk.AllocateMemory(device, &final_alloc, nil, &final_memory) != .SUCCESS {
		vk.DestroyBuffer(device, final_buffer, nil)
		return {}, false
	}

	if vk.BindBufferMemory(device, final_buffer, final_memory, 0) != .SUCCESS {
		vk.FreeMemory(device, final_memory, nil)
		vk.DestroyBuffer(device, final_buffer, nil)
		return {}, false
	}

	command_alloc := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	copy_cmd: vk.CommandBuffer
	if vk.AllocateCommandBuffers(device, &command_alloc, &copy_cmd) != .SUCCESS {
		vk.FreeMemory(device, final_memory, nil)
		vk.DestroyBuffer(device, final_buffer, nil)
		return {}, false
	}

	free_copy_cmd := false
	defer if free_copy_cmd {
		vk.FreeCommandBuffers(device, command_pool, 1, &copy_cmd)
	}

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(copy_cmd, &begin_info) != .SUCCESS {
		free_copy_cmd = true
		vk.FreeMemory(device, final_memory, nil)
		vk.DestroyBuffer(device, final_buffer, nil)
		return {}, false
	}

	copy_region := vk.BufferCopy {
		srcOffset = 0,
		dstOffset = 0,
		size      = data_size,
	}
	vk.CmdCopyBuffer(copy_cmd, staging.handle, final_buffer, 1, &copy_region)

	if vk.EndCommandBuffer(copy_cmd) != .SUCCESS {
		free_copy_cmd = true
		vk.FreeMemory(device, final_memory, nil)
		vk.DestroyBuffer(device, final_buffer, nil)
		return {}, false
	}

	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &copy_cmd,
	}
	if vk.QueueSubmit(queue, 1, &submit_info, vk.Fence(0)) != .SUCCESS {
		free_copy_cmd = true
		vk.FreeMemory(device, final_memory, nil)
		vk.DestroyBuffer(device, final_buffer, nil)
		return {}, false
	}
	if vk.QueueWaitIdle(queue) != .SUCCESS {
		free_copy_cmd = true
		vk.FreeMemory(device, final_memory, nil)
		vk.DestroyBuffer(device, final_buffer, nil)
		return {}, false
	}

	vk.FreeCommandBuffers(device, command_pool, 1, &copy_cmd)
	free_copy_cmd = false

	return Gpu_Buffer{
		handle = final_buffer,
		memory = final_memory,
	}, true
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
				result := vk.GetPhysicalDeviceSurfaceSupportKHR(
					device,
					u32(i),
					surface,
					&found_present,
				)
				if result != .SUCCESS {
					continue
				}
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

Device_Extensions :: struct {
	device: vk.PhysicalDevice,
	props:  []vk.ExtensionProperties,
}

@(private)
g_device_extensions: Device_Extensions

cache_device_extensions :: proc(device: vk.PhysicalDevice) -> bool {
	if g_device_extensions.device == device && len(g_device_extensions.props) > 0 {
		return true
	}

	if len(g_device_extensions.props) > 0 {
		delete(g_device_extensions.props, context.allocator)
		g_device_extensions = {}
	}

	count: u32 = 0
	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) != .SUCCESS || count == 0 {
		return false
	}

	props := make([]vk.ExtensionProperties, int(count), context.allocator)
	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(props)) != .SUCCESS {
		delete(props, context.allocator)
		return false
	}

	g_device_extensions = Device_Extensions {
		device = device,
		props  = props,
	}
	return true
}

device_extension_available :: proc(device: vk.PhysicalDevice, name: cstring) -> bool {
	if !cache_device_extensions(device) {
		return false
	}

	target := string(name)
	for i in 0 ..< len(g_device_extensions.props) {
		ext_name := string(cast(cstring)&g_device_extensions.props[i].extensionName[0])
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
	// Required: presentation support for window surfaces.
	append(&device_extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)

	if !device_extension_available(physical_device, vk.KHR_SWAPCHAIN_EXTENSION_NAME) {
		return {}, false
	}

	// Optional on Apple/MoltenVK: required when implementation exposes portability subset.
	if device_extension_available(physical_device, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME) {
		append(&device_extensions, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME)
	}

	// Optional fallback for Vulkan < 1.3 implementations exposing KHR dynamic rendering.
	if device_extension_available(physical_device, vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME) {
		append(&device_extensions, vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME)
	}

	// Optional fallback for Vulkan < 1.3 implementations exposing KHR synchronization2.
	if device_extension_available(physical_device, vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME) {
		append(&device_extensions, vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME)
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

	if vk.CmdPipelineBarrier2 != nil {
		vkCmdPipelineBarrier2 = vk.CmdPipelineBarrier2
	} else {
		vkCmdPipelineBarrier2 = vk.CmdPipelineBarrier2KHR
	}

	if vk.CmdBeginRendering != nil {
		vkCmdBeginRendering = vk.CmdBeginRendering
	} else {
		vkCmdBeginRendering = vk.CmdBeginRenderingKHR
	}

	if vk.CmdEndRendering != nil {
		vkCmdEndRendering = vk.CmdEndRendering
	} else {
		vkCmdEndRendering = vk.CmdEndRenderingKHR
	}

	assert(vkCmdBeginRendering != nil, "Neither vkCmdBeginRendering nor vkCmdBeginRenderingKHR loaded")
	assert(vkCmdEndRendering != nil, "Neither vkCmdEndRendering nor vkCmdEndRenderingKHR loaded")
	assert(vkCmdPipelineBarrier2 != nil, "Neither vkCmdPipelineBarrier2 nor vkCmdPipelineBarrier2KHR loaded")

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
		if props.deviceType == .DISCRETE_GPU || props.deviceType == .INTEGRATED_GPU {
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

Instance_Extensions :: struct {
	initialized: bool,
	props:       []vk.ExtensionProperties,
}

@(private)
g_instance_extensions: Instance_Extensions

cache_instance_extensions :: proc() -> bool {
	if g_instance_extensions.initialized {
		return len(g_instance_extensions.props) > 0
	}

	count: u32 = 0
	if vk.EnumerateInstanceExtensionProperties(nil, &count, nil) != .SUCCESS || count == 0 {
		g_instance_extensions.initialized = true
		return false
	}

	props := make([]vk.ExtensionProperties, int(count), context.allocator)
	if vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(props)) != .SUCCESS {
		delete(props, context.allocator)
		g_instance_extensions.initialized = true
		return false
	}

	g_instance_extensions = Instance_Extensions {
		initialized = true,
		props       = props,
	}
	return true
}

instance_extension_available :: proc(name: cstring) -> bool {
	if !cache_instance_extensions() {
		return false
	}

	name_str := string(name)
	for i in 0 ..< len(g_instance_extensions.props) {
		ext_name := string(cast(cstring)&g_instance_extensions.props[i].extensionName[0])
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

	depth_image:      vk.Image,
	depth_image_view: vk.ImageView,
	depth_memory:     vk.DeviceMemory,
}

surface_format_supports_usage :: proc(
	physical_device: vk.PhysicalDevice,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
) -> bool {
	props: vk.ImageFormatProperties
	return(
		vk.GetPhysicalDeviceImageFormatProperties(
			physical_device,
			format,
			.D2,
			.OPTIMAL,
			usage,
			{},
			&props,
		) ==
		.SUCCESS \
	)
}

// -----------------------------------------------------------------------
// Rendering data types
// -----------------------------------------------------------------------

Quad_Command :: struct {
	rect:  vec4,
	color: vec4,
}

Mesh_Vertex :: struct {
	pos:    vec3,
	normal: vec3,
	color:  vec4,
}

Mesh_Command :: struct {
	mesh:  Mesh_Handle,
	model: mat4,
	color: vec4,
}

Mesh_Push_Constants :: struct {
	mvp:   mat4,
	color: vec4,
}

Gpu_Mesh :: struct {
	vbuf:         Gpu_Buffer,
	ibuf:         Gpu_Buffer,
	index_count:  u32,
	vertex_count: u32,
	loaded:       bool,
}

Frame_Commands :: struct {
	clear_color: vec4,
	quads:       [dynamic]Quad_Command,
	meshes:      [dynamic]Mesh_Command,
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
	if .TRANSFER_SRC in capabilities.supportedUsageFlags {
		image_usage += {.TRANSFER_SRC}
	}

	validation_usage := image_usage
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

	depth_image, depth_image_view, depth_memory, ok_depth := create_depth_image(
		device,
		physical_device,
		swap_extent,
	)
	if !ok_depth {
		for created_index in 0 ..< created_image_views {
			vk.DestroyImageView(device, swapchain_image_views[created_index], nil)
		}
		vk.DestroySwapchainKHR(device, swapchain, nil)
		return {}, false
	}

	swapchain_context := SwapchainContext {
		handle       = swapchain,
		images       = swapchain_images,
		image_views  = swapchain_image_views,
		image_format = chosen_format.format,
		extent       = swap_extent,
		depth_image      = depth_image,
		depth_image_view = depth_image_view,
		depth_memory     = depth_memory,
	}
	return swapchain_context, true
}

destroy_swapchain_context :: proc(device: vk.Device, swapchain_context: ^SwapchainContext) {
	destroy_depth_image(
		device,
		swapchain_context.depth_image,
		swapchain_context.depth_image_view,
		swapchain_context.depth_memory,
	)

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
// Bindless descriptor resources
// -----------------------------------------------------------------------

create_descriptor_layout :: proc(device: vk.Device) -> (vk.DescriptorSetLayout, bool) {
	binding := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .STORAGE_BUFFER,
		descriptorCount = 1,
		stageFlags      = {.VERTEX},
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &binding,
	}
	layout: vk.DescriptorSetLayout
	if vk.CreateDescriptorSetLayout(device, &layout_info, nil, &layout) != .SUCCESS {
		return {}, false
	}
	return layout, true
}

create_quad_descriptor_pool :: proc(device: vk.Device) -> (vk.DescriptorPool, bool) {
	pool_size := vk.DescriptorPoolSize {
		type            = .STORAGE_BUFFER,
		descriptorCount = MAX_FRAMES_IN_FLIGHT,
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = MAX_FRAMES_IN_FLIGHT,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}
	pool: vk.DescriptorPool
	if vk.CreateDescriptorPool(device, &pool_info, nil, &pool) != .SUCCESS {
		return {}, false
	}
	return pool, true
}

update_quad_descriptor_sets :: proc(
	device: vk.Device,
	descriptor_sets: []vk.DescriptorSet,
	quad_ssbos: []Mapped_Buffer,
) {
	for i in 0 ..< len(descriptor_sets) {
		buffer_info := vk.DescriptorBufferInfo {
			buffer = quad_ssbos[i].handle,
			offset = 0,
			range  = vk.DeviceSize(MAX_QUADS * size_of(Quad_Command)),
		}
		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = descriptor_sets[i],
			dstBinding      = 0,
			dstArrayElement = 0,
			descriptorType  = .STORAGE_BUFFER,
			descriptorCount = 1,
			pBufferInfo     = &buffer_info,
		}
		vk.UpdateDescriptorSets(device, 1, &write, 0, nil)
	}
}

// -----------------------------------------------------------------------
// Semaphores & swapchain recreation
// -----------------------------------------------------------------------

recreate_swapchain :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	indices: QueueFamilyIndices,
	swapchain_allocator: mem.Allocator,
	swapchain_context: ^SwapchainContext,
) -> bool {
	if vk.DeviceWaitIdle(device) == .ERROR_DEVICE_LOST {
		return false
	}
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
	depth_image: vk.Image,
	depth_image_view: vk.ImageView,
	extent: vk.Extent2D,
	pipeline: vk.Pipeline,
	layout: vk.PipelineLayout,
	mesh_pipeline: vk.Pipeline,
	mesh_layout: vk.PipelineLayout,
	meshes: ^[MAX_MESHES]Gpu_Mesh,
	descriptor_set: vk.DescriptorSet,
	clear_color: vec4,
	quad_count: int,
	mesh_commands: []Mesh_Command,
	view_matrix: mat4,
	proj_matrix: mat4,
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

	vkCmdPipelineBarrier2(cmd, &dependency_info)

	depth_barrier := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.TOP_OF_PIPE},
		srcAccessMask    = {},
		dstStageMask     = {.EARLY_FRAGMENT_TESTS},
		dstAccessMask    = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
		oldLayout        = .UNDEFINED,
		newLayout        = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		image            = depth_image,
		subresourceRange = {{.DEPTH}, 0, 1, 0, 1},
	}

	depth_dependency := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &depth_barrier,
	}
	vkCmdPipelineBarrier2(cmd, &depth_dependency)

	clear := clear_color
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

	depth_clear_value := vk.ClearValue {
		depthStencil = {depth = 1.0, stencil = 0},
	}
	depth_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = depth_image_view,
		imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .DONT_CARE,
		clearValue  = depth_clear_value,
	}

	// Begin dynamic rendering
	render_info := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = {{0, 0}, extent},
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment,
		pDepthAttachment     = &depth_attachment,
	}

	vkCmdBeginRendering(cmd, &render_info)

	// Bind pipeline and set dynamic state
	vk.CmdBindPipeline(cmd, .GRAPHICS, pipeline)
	ds := descriptor_set
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, layout, 0, 1, &ds, 0, nil)

	viewports := vk.Viewport{0.0, 0.0, f32(extent.width), f32(extent.height), 0.0, 1.0}
	vk.CmdSetViewport(cmd, 0, 1, &viewports)

	rect := vk.Rect2D{{0, 0}, extent}
	vk.CmdSetScissor(cmd, 0, 1, &rect)

	if quad_count > 0 {
		vk.CmdDraw(cmd, 6, u32(quad_count), 0, 0)
	}

	if len(mesh_commands) > 0 {
		vk.CmdBindPipeline(cmd, .GRAPHICS, mesh_pipeline)
		last_mesh := -1

		for mesh_cmd in mesh_commands {
			mesh_index := int(cast(u32)mesh_cmd.mesh)
			if mesh_index < 0 || mesh_index >= MAX_MESHES {
				continue
			}

			gpu_mesh := &meshes[mesh_index]
			if !gpu_mesh.loaded || gpu_mesh.index_count == 0 {
				continue
			}

			if last_mesh != mesh_index {
				vbuf := gpu_mesh.vbuf.handle
				vbuf_offset: vk.DeviceSize = 0
				vk.CmdBindVertexBuffers(cmd, 0, 1, &vbuf, &vbuf_offset)
				vk.CmdBindIndexBuffer(cmd, gpu_mesh.ibuf.handle, 0, .UINT32)
				last_mesh = mesh_index
			}

			mvp := proj_matrix * view_matrix * mesh_cmd.model
			push := Mesh_Push_Constants {
				mvp   = mvp,
				color = mesh_cmd.color,
			}
			vk.CmdPushConstants(
				cmd,
				mesh_layout,
				{.VERTEX, .FRAGMENT},
				0,
				u32(size_of(Mesh_Push_Constants)),
				&push,
			)
			vk.CmdDrawIndexed(cmd, gpu_mesh.index_count, 1, 0, 0, 0)
		}
	}

	vkCmdEndRendering(cmd)

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
	vkCmdPipelineBarrier2(cmd, &end_dependency_info)

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

	return value[len(value) - len(suffix):] == suffix
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
	descriptor_layout: vk.DescriptorSetLayout,
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

	dl := descriptor_layout
	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts    = &dl,
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

create_mesh_pipeline :: proc(
	device: vk.Device,
	image_format: vk.Format,
	depth_format: vk.Format,
	shader_stages: []vk.PipelineShaderStageCreateInfo,
	descriptor_layout: vk.DescriptorSetLayout,
) -> (
	vk.PipelineLayout,
	vk.Pipeline,
	bool,
) {
	vertex_binding := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = size_of(Mesh_Vertex),
		inputRate = .VERTEX,
	}
	vertex_attributes := [3]vk.VertexInputAttributeDescription{
		{
			location = 0,
			binding  = 0,
			format   = .R32G32B32_SFLOAT,
			offset   = 0,
		},
		{
			location = 1,
			binding  = 0,
			format   = .R32G32B32_SFLOAT,
			offset   = size_of(vec3),
		},
		{
			location = 2,
			binding  = 0,
			format   = .R32G32B32A32_SFLOAT,
			offset   = size_of(vec3) * 2,
		},
	}

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &vertex_binding,
		vertexAttributeDescriptionCount = u32(len(vertex_attributes)),
		pVertexAttributeDescriptions    = &vertex_attributes[0],
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
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
		frontFace               = .COUNTER_CLOCKWISE,
		depthBiasEnable         = false,
		lineWidth               = 1.0,
	}

	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
		sampleShadingEnable  = false,
	}

	depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = true,
		depthWriteEnable = true,
		depthCompareOp   = .LESS,
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
		size       = u32(size_of(Mesh_Push_Constants)),
	}

	dl := descriptor_layout
	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &dl,
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
		depthAttachmentFormat   = depth_format,
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering_info,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pDepthStencilState  = &depth_stencil,
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
	mesh_shader_stages: []vk.PipelineShaderStageCreateInfo,
	mesh_pipeline_layout: ^vk.PipelineLayout,
	mesh_pipeline: ^vk.Pipeline,
	descriptor_layout: vk.DescriptorSetLayout,
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
		descriptor_layout,
	)
	if !ok_pipeline {
		return false
	}

	new_mesh_pipeline_layout, new_mesh_pipeline, ok_mesh_pipeline := create_mesh_pipeline(
		device,
		swapchain_context.image_format,
		.D32_SFLOAT,
		mesh_shader_stages,
		descriptor_layout,
	)
	if !ok_mesh_pipeline {
		vk.DestroyPipeline(device, new_graphics_pipeline, nil)
		vk.DestroyPipelineLayout(device, new_pipeline_layout, nil)
		return false
	}

	vk.DestroyPipeline(device, graphics_pipeline^, nil)
	vk.DestroyPipelineLayout(device, pipeline_layout^, nil)
	vk.DestroyPipeline(device, mesh_pipeline^, nil)
	vk.DestroyPipelineLayout(device, mesh_pipeline_layout^, nil)

	graphics_pipeline^ = new_graphics_pipeline
	pipeline_layout^ = new_pipeline_layout
	mesh_pipeline^ = new_mesh_pipeline
	mesh_pipeline_layout^ = new_mesh_pipeline_layout

	return true
}
