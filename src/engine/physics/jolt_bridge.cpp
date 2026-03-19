#include <Jolt/Jolt.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/JobSystemSingleThreaded.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Collision/ContactListener.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/StaticCompoundShape.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/RegisterTypes.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <mutex>
#include <utility>
#include <vector>

namespace {
constexpr uint32_t kFlagHasBox = 1u << 0;
constexpr uint32_t kFlagHasSphere = 1u << 1;
constexpr uint32_t kFlagHasMeshProxy = 1u << 2;
constexpr uint32_t kFlagBodyIsSensor = 1u << 3;
constexpr uint32_t kFlagAllowSleep = 1u << 4;

namespace Layers {
static constexpr JPH::ObjectLayer NON_MOVING = 0;
static constexpr JPH::ObjectLayer MOVING = 1;
static constexpr JPH::ObjectLayer NUM_LAYERS = 2;
} // namespace Layers

namespace BroadPhaseLayers {
static constexpr JPH::BroadPhaseLayer NON_MOVING(0);
static constexpr JPH::BroadPhaseLayer MOVING(1);
static constexpr uint NUM_LAYERS = 2;
} // namespace BroadPhaseLayers

class BroadPhaseLayerInterfaceImpl final
    : public JPH::BroadPhaseLayerInterface {
public:
  BroadPhaseLayerInterfaceImpl() {
    m_object_to_broad_phase[Layers::NON_MOVING] = BroadPhaseLayers::NON_MOVING;
    m_object_to_broad_phase[Layers::MOVING] = BroadPhaseLayers::MOVING;
  }

  uint GetNumBroadPhaseLayers() const override {
    return BroadPhaseLayers::NUM_LAYERS;
  }

  JPH::BroadPhaseLayer
  GetBroadPhaseLayer(JPH::ObjectLayer in_layer) const override {
    return m_object_to_broad_phase[in_layer];
  }

#if defined(JPH_EXTERNAL_PROFILE) || defined(JPH_PROFILE_ENABLED)
  const char *
  GetBroadPhaseLayerName(JPH::BroadPhaseLayer in_layer) const override {
    switch (static_cast<JPH::BroadPhaseLayer::Type>(in_layer)) {
    case static_cast<JPH::BroadPhaseLayer::Type>(BroadPhaseLayers::NON_MOVING):
      return "NON_MOVING";
    case static_cast<JPH::BroadPhaseLayer::Type>(BroadPhaseLayers::MOVING):
      return "MOVING";
    default:
      return "INVALID";
    }
  }
#endif

private:
  std::array<JPH::BroadPhaseLayer, Layers::NUM_LAYERS>
      m_object_to_broad_phase{};
};

class ObjectVsBroadPhaseLayerFilterImpl final
    : public JPH::ObjectVsBroadPhaseLayerFilter {
public:
  bool ShouldCollide(JPH::ObjectLayer in_layer1,
                     JPH::BroadPhaseLayer in_layer2) const override {
    switch (in_layer1) {
    case Layers::NON_MOVING:
      return in_layer2 == BroadPhaseLayers::MOVING;
    case Layers::MOVING:
      return true;
    default:
      return false;
    }
  }
};

class ObjectLayerPairFilterImpl final : public JPH::ObjectLayerPairFilter {
public:
  bool ShouldCollide(JPH::ObjectLayer in_object1,
                     JPH::ObjectLayer in_object2) const override {
    switch (in_object1) {
    case Layers::NON_MOVING:
      return in_object2 == Layers::MOVING;
    case Layers::MOVING:
      return true;
    default:
      return false;
    }
  }
};

class CountingContactListener final : public JPH::ContactListener {
public:
  void OnContactAdded(const JPH::Body &, const JPH::Body &,
                      const JPH::ContactManifold &,
                      JPH::ContactSettings &) override {
    ++m_count;
  }

  uint32_t GetCount() const { return m_count; }

private:
  uint32_t m_count = 0;
};

struct Globals {
  Globals() {
    JPH::RegisterDefaultAllocator();
    JPH::Factory::sInstance = new JPH::Factory();
    JPH::RegisterTypes();
  }

  ~Globals() {
    JPH::UnregisterTypes();
    delete JPH::Factory::sInstance;
    JPH::Factory::sInstance = nullptr;
  }
};

void EnsureInitialized() {
  static std::once_flag once;
  std::call_once(once, []() {
    static Globals globals;
    (void)globals;
  });
}

JPH::Vec3 ToVec3(const float in_value[3]) {
  return JPH::Vec3(in_value[0], in_value[1], in_value[2]);
}

JPH::RVec3 ToRVec3(const float in_value[3]) {
  return JPH::RVec3(in_value[0], in_value[1], in_value[2]);
}

JPH::Quat ToQuat(const float in_value[4]) {
  return JPH::Quat(in_value[0], in_value[1], in_value[2], in_value[3]);
}

JPH::EMotionType ToMotionType(uint32_t in_motion_type) {
  switch (in_motion_type) {
  case 0:
    return JPH::EMotionType::Static;
  case 2:
    return JPH::EMotionType::Kinematic;
  default:
    return JPH::EMotionType::Dynamic;
  }
}

JPH::ObjectLayer ToObjectLayer(JPH::EMotionType in_motion_type) {
  return in_motion_type == JPH::EMotionType::Dynamic ? Layers::MOVING
                                                     : Layers::NON_MOVING;
}
} // namespace

extern "C" {
struct GuavaJoltBodyDesc {
  uint64_t entity_id;
  uint32_t motion_type;
  uint32_t flags;
  float mass;
  float gravity_scale;
  float linear_damping;
  float max_linear_speed;
  float position[3];
  float rotation[4];
  float linear_velocity[3];
  float box_half_extents[3];
  float box_center[3];
  float sphere_radius;
  float sphere_center[3];
  float mesh_half_extents[3];
  float mesh_center[3];
};

struct GuavaJoltStepConfig {
  float delta_seconds;
  float gravity[3];
  uint32_t collision_steps;
  uint32_t temp_allocator_size_bytes;
  uint32_t max_bodies;
  uint32_t num_body_mutexes;
  uint32_t max_body_pairs;
  uint32_t max_contact_constraints;
};

struct GuavaJoltBodyState {
  uint64_t entity_id;
  float position[3];
  float rotation[4];
  float linear_velocity[3];
};

struct GuavaJoltStepStats {
  uint32_t dynamic_bodies;
  uint32_t static_bodies;
  uint32_t contacts_resolved;
  uint32_t state_count;
  uint8_t success;
  uint8_t reserved0;
  uint16_t reserved1;
};

bool guava_jolt_step(const GuavaJoltBodyDesc *in_bodies, size_t in_body_count,
                     const GuavaJoltStepConfig *in_config,
                     GuavaJoltBodyState *out_states, size_t in_state_capacity,
                     GuavaJoltStepStats *out_stats) {
  if (out_stats == nullptr || in_config == nullptr) {
    return false;
  }

  *out_stats = {};
  EnsureInitialized();

  BroadPhaseLayerInterfaceImpl broad_phase_layer_interface;
  ObjectVsBroadPhaseLayerFilterImpl object_vs_broad_phase_layer_filter;
  ObjectLayerPairFilterImpl object_layer_pair_filter;
  CountingContactListener contact_listener;

  const uint32_t max_bodies = std::max<uint32_t>(
      in_config->max_bodies, static_cast<uint32_t>(in_body_count) + 16);
  const uint32_t max_pairs = std::max<uint32_t>(
      in_config->max_body_pairs, static_cast<uint32_t>(in_body_count) * 4 + 16);
  const uint32_t max_contacts =
      std::max<uint32_t>(in_config->max_contact_constraints,
                         static_cast<uint32_t>(in_body_count) * 8 + 16);
  const uint32_t allocator_size =
      std::max<uint32_t>(in_config->temp_allocator_size_bytes, 1024 * 1024);
  const int collision_steps =
      std::max<int>(1, static_cast<int>(in_config->collision_steps));

  JPH::PhysicsSystem physics_system;
  physics_system.Init(max_bodies, in_config->num_body_mutexes, max_pairs,
                      max_contacts, broad_phase_layer_interface,
                      object_vs_broad_phase_layer_filter,
                      object_layer_pair_filter);
  physics_system.SetGravity(ToVec3(in_config->gravity));
  physics_system.SetContactListener(&contact_listener);

  JPH::TempAllocatorImpl temp_allocator(static_cast<int>(allocator_size));
  JPH::JobSystemSingleThreaded job_system;
  JPH::BodyInterface &body_interface = physics_system.GetBodyInterface();

  std::vector<JPH::BodyID> created_ids;
  std::vector<std::pair<uint64_t, JPH::BodyID>> body_lookup;
  created_ids.reserve(in_body_count);
  body_lookup.reserve(in_body_count);

  for (size_t i = 0; i < in_body_count; ++i) {
    const GuavaJoltBodyDesc &desc = in_bodies[i];
    const JPH::EMotionType motion_type = ToMotionType(desc.motion_type);

    int shape_count = 0;
    JPH::StaticCompoundShapeSettings compound_settings;

    if ((desc.flags & kFlagHasBox) != 0) {
      JPH::Vec3 half_extents = ToVec3(desc.box_half_extents);
      if (half_extents.ReduceMin() > 0.0f) {
        compound_settings.AddShape(ToVec3(desc.box_center),
                                   JPH::Quat::sIdentity(),
                                   new JPH::BoxShape(half_extents));
        ++shape_count;
      }
    }

    if ((desc.flags & kFlagHasSphere) != 0 && desc.sphere_radius > 0.0f) {
      compound_settings.AddShape(ToVec3(desc.sphere_center),
                                 JPH::Quat::sIdentity(),
                                 new JPH::SphereShape(desc.sphere_radius));
      ++shape_count;
    }

    if ((desc.flags & kFlagHasMeshProxy) != 0) {
      JPH::Vec3 half_extents = ToVec3(desc.mesh_half_extents);
      if (half_extents.ReduceMin() > 0.0f) {
        compound_settings.AddShape(ToVec3(desc.mesh_center),
                                   JPH::Quat::sIdentity(),
                                   new JPH::BoxShape(half_extents));
        ++shape_count;
      }
    }

    if (shape_count == 0)
      continue;

    JPH::Shape::ShapeResult shape_result = compound_settings.Create();
    if (shape_result.HasError())
      return false;

    JPH::ShapeRefC shape = shape_result.Get();
    JPH::BodyCreationSettings settings(shape.GetPtr(), ToRVec3(desc.position),
                                       ToQuat(desc.rotation), motion_type,
                                       ToObjectLayer(motion_type));
    settings.mUserData = desc.entity_id;
    settings.mLinearVelocity = ToVec3(desc.linear_velocity);
    settings.mAllowSleeping = (desc.flags & kFlagAllowSleep) != 0;
    settings.mIsSensor = (desc.flags & kFlagBodyIsSensor) != 0;
    settings.mCollideKinematicVsNonDynamic =
        motion_type == JPH::EMotionType::Kinematic || settings.mIsSensor;
    settings.mLinearDamping = desc.linear_damping;
    settings.mMaxLinearVelocity = desc.max_linear_speed;
    settings.mGravityFactor = desc.gravity_scale;
    if (motion_type != JPH::EMotionType::Static) {
      settings.mOverrideMassProperties =
          JPH::EOverrideMassProperties::CalculateInertia;
      settings.mMassPropertiesOverride.mMass = std::max(desc.mass, 0.001f);
    }

    const JPH::EActivation activation = motion_type == JPH::EMotionType::Dynamic
                                            ? JPH::EActivation::Activate
                                            : JPH::EActivation::DontActivate;
    const JPH::BodyID body_id =
        body_interface.CreateAndAddBody(settings, activation);
    if (!body_id.IsInvalid()) {
      created_ids.push_back(body_id);
      body_lookup.emplace_back(desc.entity_id, body_id);
      switch (motion_type) {
      case JPH::EMotionType::Dynamic:
        ++out_stats->dynamic_bodies;
        break;
      case JPH::EMotionType::Static:
      case JPH::EMotionType::Kinematic:
        ++out_stats->static_bodies;
        break;
      }
    }
  }

  const JPH::EPhysicsUpdateError update_error = physics_system.Update(
      in_config->delta_seconds, collision_steps, &temp_allocator, &job_system);
  if (update_error != JPH::EPhysicsUpdateError::None) {
    return false;
  }

  size_t out_index = 0;
  for (size_t i = 0; i < in_body_count && out_index < in_state_capacity; ++i) {
    const GuavaJoltBodyDesc &desc = in_bodies[i];
    const JPH::EMotionType motion_type = ToMotionType(desc.motion_type);
    if (motion_type == JPH::EMotionType::Static)
      continue;

    JPH::RVec3 position = ToRVec3(desc.position);
    JPH::Quat rotation = ToQuat(desc.rotation);
    JPH::Vec3 linear_velocity = ToVec3(desc.linear_velocity);

    for (const auto &entry : body_lookup) {
      if (entry.first == desc.entity_id) {
        body_interface.GetPositionAndRotation(entry.second, position, rotation);
        linear_velocity = body_interface.GetLinearVelocity(entry.second);
        break;
      }
    }

    GuavaJoltBodyState &state = out_states[out_index++];
    state.entity_id = desc.entity_id;
    state.position[0] = static_cast<float>(position.GetX());
    state.position[1] = static_cast<float>(position.GetY());
    state.position[2] = static_cast<float>(position.GetZ());
    state.rotation[0] = rotation.GetX();
    state.rotation[1] = rotation.GetY();
    state.rotation[2] = rotation.GetZ();
    state.rotation[3] = rotation.GetW();
    state.linear_velocity[0] = linear_velocity.GetX();
    state.linear_velocity[1] = linear_velocity.GetY();
    state.linear_velocity[2] = linear_velocity.GetZ();
  }

  for (const JPH::BodyID &body_id : created_ids) {
    if (body_interface.IsAdded(body_id))
      body_interface.RemoveBody(body_id);
  }
  if (!created_ids.empty())
    body_interface.DestroyBodies(created_ids.data(),
                                 static_cast<int>(created_ids.size()));

  out_stats->contacts_resolved = contact_listener.GetCount();
  out_stats->state_count = static_cast<uint32_t>(out_index);
  out_stats->success = 1;
  return true;
}
}
