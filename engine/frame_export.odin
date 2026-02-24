package engine

import "core:fmt"
import "core:mem"
import "core:os"
import vk "vendor:vulkan"

// -----------------------------------------------------------------------
// Frame export — headless frame capture to BMP for debug analysis
// -----------------------------------------------------------------------

Frame_Export_Config :: struct {
	enabled:    bool,
	num_frames: int,
	output_dir: string,
}

Frame_Export_Resources :: struct {
	staging:  Mapped_Buffer,
	copy_cmd: vk.CommandBuffer,
}

parse_frame_export_args :: proc() -> Frame_Export_Config {
	config := Frame_Export_Config {
		num_frames = 1,
		output_dir = "frames",
	}

	args := os.args
	i := 1 // skip program name
	for i < len(args) {
		arg := args[i]
		if arg == "--headless" || arg == "-H" {
			config.enabled = true
		} else if arg == "--frames" || arg == "-f" {
			i += 1
			if i < len(args) {
				n := parse_positive_int(args[i])
				if n > 0 {
					config.num_frames = n
				}
			}
		} else if arg == "--output-dir" || arg == "-o" {
			i += 1
			if i < len(args) {
				config.output_dir = args[i]
			}
		}
		i += 1
	}

	return config
}

create_frame_export_resources :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	command_pool: vk.CommandPool,
	extent: vk.Extent2D,
) -> (Frame_Export_Resources, bool) {
	res: Frame_Export_Resources

	// Staging buffer: width * height * 4 bytes (BGRA)
	data_size := vk.DeviceSize(extent.width) * vk.DeviceSize(extent.height) * 4
	staging, ok_staging := create_mapped_buffer(device, physical_device, data_size, {.TRANSFER_DST})
	if !ok_staging {
		log_error("Failed to create frame export staging buffer")
		return {}, false
	}
	res.staging = staging

	// Allocate a reusable command buffer for copy operations
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	if vk.AllocateCommandBuffers(device, &alloc_info, &res.copy_cmd) != .SUCCESS {
		log_error("Failed to allocate frame export command buffer")
		destroy_mapped_buffer(device, &res.staging)
		return {}, false
	}

	return res, true
}

destroy_frame_export_resources :: proc(device: vk.Device, res: ^Frame_Export_Resources) {
	destroy_mapped_buffer(device, &res.staging)
	// Command buffer is freed when the pool is destroyed
}

// Record commands to copy a swapchain image into the staging buffer.
// Assumes the source image is in PRESENT_SRC_KHR layout on entry,
// and leaves it in PRESENT_SRC_KHR on exit.
record_copy_commands :: proc(
	cmd: vk.CommandBuffer,
	src_image: vk.Image,
	dst_buffer: vk.Buffer,
	extent: vk.Extent2D,
) -> bool {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	if vk.BeginCommandBuffer(cmd, &begin_info) != .SUCCESS {
		return false
	}

	// Transition: PRESENT_SRC_KHR → TRANSFER_SRC_OPTIMAL
	to_transfer := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.BOTTOM_OF_PIPE},
		srcAccessMask       = {},
		dstStageMask        = {.TRANSFER},
		dstAccessMask       = {.TRANSFER_READ},
		oldLayout           = .PRESENT_SRC_KHR,
		newLayout           = .TRANSFER_SRC_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = src_image,
		subresourceRange    = {{.COLOR}, 0, 1, 0, 1},
	}
	dep1 := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &to_transfer,
	}
	vkCmdPipelineBarrier2(cmd, &dep1)

	// Copy image to buffer
	region := vk.BufferImageCopy {
		bufferOffset      = 0,
		bufferRowLength   = 0, // tightly packed
		bufferImageHeight = 0, // tightly packed
		imageSubresource  = {
			aspectMask     = {.COLOR},
			mipLevel       = 0,
			baseArrayLayer = 0,
			layerCount     = 1,
		},
		imageOffset       = {0, 0, 0},
		imageExtent       = {extent.width, extent.height, 1},
	}
	vk.CmdCopyImageToBuffer(cmd, src_image, .TRANSFER_SRC_OPTIMAL, dst_buffer, 1, &region)

	// Transition back: TRANSFER_SRC_OPTIMAL → PRESENT_SRC_KHR
	to_present := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.TRANSFER},
		srcAccessMask       = {.TRANSFER_READ},
		dstStageMask        = {.BOTTOM_OF_PIPE},
		dstAccessMask       = {},
		oldLayout           = .TRANSFER_SRC_OPTIMAL,
		newLayout           = .PRESENT_SRC_KHR,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = src_image,
		subresourceRange    = {{.COLOR}, 0, 1, 0, 1},
	}
	dep2 := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &to_present,
	}
	vkCmdPipelineBarrier2(cmd, &dep2)

	if vk.EndCommandBuffer(cmd) != .SUCCESS {
		return false
	}
	return true
}

// Write raw BGRA pixel data to a BMP file.
write_bmp :: proc(dir: string, frame_num: int, pixels: rawptr, width, height: u32) -> bool {
	pixel_data_size := int(width) * int(height) * 4
	total_size := 54 + pixel_data_size

	data := make([]byte, total_size, context.temp_allocator)

	// File header (14 bytes)
	data[0] = 'B'
	data[1] = 'M'
	write_le_u32(data, 2, u32(total_size))
	// bytes 6-9: reserved (zero)
	write_le_u32(data, 10, 54) // pixel data offset

	// DIB header — BITMAPINFOHEADER (40 bytes)
	write_le_u32(data, 14, 40) // header size
	write_le_i32(data, 18, i32(width))
	write_le_i32(data, 22, -i32(height)) // negative = top-down rows
	write_le_u16(data, 26, 1)            // planes
	write_le_u16(data, 28, 32)           // bits per pixel
	// bytes 30-53: compression, image size, resolution, palette (zero)

	// Copy pixel data after header
	mem.copy(raw_data(data[54:]), pixels, pixel_data_size)

	filename := fmt.tprintf("%s/frame_%04d.bmp", dir, frame_num)
	if !os.write_entire_file(filename, data) {
		log_errorf("Failed to write %s", filename)
		return false
	}

	return true
}

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

@(private)
write_le_u32 :: proc(buf: []byte, offset: int, val: u32) {
	buf[offset + 0] = byte(val)
	buf[offset + 1] = byte(val >> 8)
	buf[offset + 2] = byte(val >> 16)
	buf[offset + 3] = byte(val >> 24)
}

@(private)
write_le_u16 :: proc(buf: []byte, offset: int, val: u16) {
	buf[offset + 0] = byte(val)
	buf[offset + 1] = byte(val >> 8)
}

@(private)
write_le_i32 :: proc(buf: []byte, offset: int, val: i32) {
	write_le_u32(buf, offset, transmute(u32)val)
}

@(private)
parse_positive_int :: proc(s: string) -> int {
	result := 0
	for c in s {
		if c < '0' || c > '9' {
			return 0
		}
		result = result * 10 + int(c - '0')
	}
	return result
}
