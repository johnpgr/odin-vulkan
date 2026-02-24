package engine

import "vendor:cgltf"

load_gltf_mesh :: proc(
	path: cstring,
) -> (
	vertices: []Mesh_Vertex,
	indices: []u32,
	ok: bool,
) {
	opts: cgltf.options

	gltf_data, parse_res := cgltf.parse_file(opts, path)
	if parse_res != .success || gltf_data == nil {
		log_warnf("cgltf parse failed for %s: %v", string(path), parse_res)
		return {}, {}, false
	}
	defer cgltf.free(gltf_data)

	buf_res := cgltf.load_buffers(opts, gltf_data, path)
	if buf_res != .success {
		log_warnf("cgltf load_buffers failed for %s: %v", string(path), buf_res)
		return {}, {}, false
	}

	if len(gltf_data.meshes) == 0 {
		log_warnf("No meshes in glTF %s", string(path))
		return {}, {}, false
	}

	mesh := gltf_data.meshes[0]
	if len(mesh.primitives) == 0 {
		log_warnf("No primitives in first mesh for %s", string(path))
		return {}, {}, false
	}
	total_vertices := 0
	total_indices := 0

	for prim in mesh.primitives {
		if prim.type != .triangles {
			continue
		}

		position_acc: ^cgltf.accessor
		for attr in prim.attributes {
			if attr.type == .position {
				position_acc = attr.data
				break
			}
		}

		if position_acc == nil || position_acc.count == 0 {
			continue
		}

		vertex_count := int(position_acc.count)
		total_vertices += vertex_count

		if prim.indices != nil && prim.indices.count > 0 {
			total_indices += int(prim.indices.count)
		} else {
			total_indices += vertex_count
		}
	}

	if total_vertices == 0 || total_indices == 0 {
		log_warnf("No triangle primitive geometry in %s", string(path))
		return {}, {}, false
	}

	vertices = make([]Mesh_Vertex, total_vertices, context.temp_allocator)
	indices = make([]u32, total_indices, context.temp_allocator)

	vertex_offset := 0
	index_offset := 0

	for prim in mesh.primitives {
		if prim.type != .triangles {
			continue
		}

		position_acc: ^cgltf.accessor
		normal_acc: ^cgltf.accessor
		color_acc: ^cgltf.accessor

		for attr in prim.attributes {
			#partial switch attr.type {
			case .position:
				position_acc = attr.data
			case .normal:
				normal_acc = attr.data
			case .color:
				color_acc = attr.data
			}
		}

		if position_acc == nil || position_acc.count == 0 {
			continue
		}

		vertex_count := int(position_acc.count)
		positions := make([]f32, vertex_count * 3, context.temp_allocator)
		unpacked_positions := cgltf.accessor_unpack_floats(
			position_acc,
			raw_data(positions),
			uint(len(positions)),
		)
		if int(unpacked_positions) < len(positions) {
			log_warnf("Could not unpack full position stream in %s", string(path))
			return {}, {}, false
		}

		normals: []f32
		if normal_acc != nil && int(normal_acc.count) >= vertex_count {
			normals = make([]f32, vertex_count * 3, context.temp_allocator)
			unpacked_normals := cgltf.accessor_unpack_floats(
				normal_acc,
				raw_data(normals),
				uint(len(normals)),
			)
			if int(unpacked_normals) < len(normals) {
				normals = nil
			}
		}

		color_components := 0
		colors: []f32
		if color_acc != nil && int(color_acc.count) >= vertex_count {
			color_components = int(cgltf.num_components(color_acc.type))
			if color_components == 3 || color_components == 4 {
				colors = make([]f32, vertex_count * color_components, context.temp_allocator)
				unpacked_colors := cgltf.accessor_unpack_floats(
					color_acc,
					raw_data(colors),
					uint(len(colors)),
				)
				if int(unpacked_colors) < len(colors) {
					colors = nil
					color_components = 0
				}
			}
		}

		for i in 0 ..< vertex_count {
			base_pos := i * 3
			dst_index := vertex_offset + i

			nx: f32 = 0
			ny: f32 = 1
			nz: f32 = 0
			if len(normals) > 0 {
				nx = normals[base_pos + 0]
				ny = normals[base_pos + 1]
				nz = normals[base_pos + 2]
			}

			cr: f32 = 1
			cg: f32 = 1
			cb: f32 = 1
			ca: f32 = 1
			if len(colors) > 0 {
				base_color := i * color_components
				cr = colors[base_color + 0]
				cg = colors[base_color + 1]
				cb = colors[base_color + 2]
				if color_components == 4 {
					ca = colors[base_color + 3]
				}
			}

			vertices[dst_index] = Mesh_Vertex {
				pos    = {positions[base_pos + 0], positions[base_pos + 1], positions[base_pos + 2]},
				normal = {nx, ny, nz},
				color  = {cr, cg, cb, ca},
			}
		}

		base_vertex := u32(vertex_offset)
		if prim.indices != nil && prim.indices.count > 0 {
			index_count := int(prim.indices.count)
			unpacked_indices := cgltf.accessor_unpack_indices(
				prim.indices,
				raw_data(indices[index_offset:]),
				uint(size_of(u32)),
				uint(index_count),
			)
			if int(unpacked_indices) < index_count {
				log_warnf("Could not unpack full index stream in %s", string(path))
				return {}, {}, false
			}
			for i in 0 ..< index_count {
				indices[index_offset + i] += base_vertex
			}
			index_offset += index_count
		} else {
			for i in 0 ..< vertex_count {
				indices[index_offset + i] = base_vertex + u32(i)
			}
			index_offset += vertex_count
		}

		vertex_offset += vertex_count
	}

	if vertex_offset == 0 || index_offset == 0 {
		log_warnf("No geometry decoded from %s", string(path))
		return {}, {}, false
	}

	return vertices[:vertex_offset], indices[:index_offset], true
}
