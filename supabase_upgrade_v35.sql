-- Anime GGAI Library V35 — No email verification required + Auto Creator profile for Admin
-- Run once in Supabase SQL Editor. Safe to re-run; preserves all existing data.

ALTER TABLE public.creator_profiles
  ADD COLUMN IF NOT EXISTS username text,
  ADD COLUMN IF NOT EXISTS approval_status text;

UPDATE public.creator_profiles p
SET username = COALESCE(NULLIF(p.username,''), NULLIF(u.raw_user_meta_data->>'username',''), NULLIF(split_part(u.email,'@',1),''))
FROM auth.users u
WHERE u.id=p.user_id AND (p.username IS NULL OR p.username='');

UPDATE public.creator_profiles
SET approval_status = CASE WHEN is_approved THEN 'approved' ELSE 'pending' END
WHERE approval_status IS NULL OR approval_status='' OR (is_approved=false AND approval_status='approved');

ALTER TABLE public.creator_profiles ALTER COLUMN approval_status SET DEFAULT 'approved';
ALTER TABLE public.creator_profiles ALTER COLUMN approval_status SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS creator_profiles_username_lower_uidx
ON public.creator_profiles (lower(username)) WHERE username IS NOT NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.creator_profiles TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'creator_profiles'
      AND policyname = 'creator_profiles_delete_own_rejected'
  ) THEN
    CREATE POLICY creator_profiles_delete_own_rejected
    ON public.creator_profiles
    FOR DELETE
    TO authenticated
    USING (auth.uid() = user_id);
  END IF;
END
$$;

-- 1. Auto-create & auto-approve Creator profiles for all existing Admins
INSERT INTO public.creator_profiles (user_id, display_name, handle, username, is_approved, approval_status)
SELECT
  a.user_id,
  COALESCE(NULLIF(trim(u.raw_user_meta_data->>'display_name'), ''), NULLIF(trim(u.raw_user_meta_data->>'username'), ''), 'Admin'),
  'admin-' || left(replace(a.user_id::text, '-', ''), 6),
  NULLIF(trim(u.raw_user_meta_data->>'username'), ''),
  true,
  'approved'
FROM public.app_admins a
JOIN auth.users u ON u.id = a.user_id
ON CONFLICT (user_id) DO UPDATE
SET is_approved = true,
    approval_status = 'approved';

-- 2. Trigger: automatically create Creator profile upon signup WITHOUT waiting for email confirmation
-- (If user is in app_admins, automatically set is_approved = true & approval_status = 'approved')
CREATE OR REPLACE FUNCTION public.handle_new_creator_signup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  creator_name text;
  creator_handle text;
  is_admin_user boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM public.app_admins WHERE user_id = NEW.id) INTO is_admin_user;

  IF NEW.raw_user_meta_data->>'account_type' = 'creator' OR is_admin_user THEN
    creator_name := COALESCE(
      NULLIF(trim(NEW.raw_user_meta_data->>'display_name'), ''),
      NULLIF(trim(NEW.raw_user_meta_data->>'username'), ''),
      split_part(COALESCE(NEW.email, 'creator'), '@', 1),
      'Creator'
    );
    creator_handle := trim(both '-' from regexp_replace(lower(creator_name), '[^a-z0-9]+', '-', 'g'));
    creator_handle := COALESCE(NULLIF(creator_handle, ''), 'creator') || '-' || left(replace(NEW.id::text, '-', ''), 5);

    INSERT INTO public.creator_profiles
      (user_id, display_name, handle, username, is_approved, approval_status)
    VALUES
      (NEW.id, creator_name, creator_handle, NULLIF(trim(NEW.raw_user_meta_data->>'username'), ''), is_admin_user, CASE WHEN is_admin_user THEN 'approved' ELSE 'pending' END)
    ON CONFLICT (user_id) DO UPDATE
      SET display_name = EXCLUDED.display_name,
          is_approved = CASE WHEN is_admin_user THEN true ELSE creator_profiles.is_approved END,
          approval_status = CASE WHEN is_admin_user THEN 'approved' ELSE creator_profiles.approval_status END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created_creator_profile ON auth.users;
CREATE TRIGGER on_auth_user_created_creator_profile
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.handle_new_creator_signup();

DROP TRIGGER IF EXISTS on_auth_user_confirmed_creator_profile ON auth.users;

-- 3. Trigger: whenever a user is added to app_admins, auto-create/approve their Creator profile
CREATE OR REPLACE FUNCTION public.handle_new_admin_creator_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  u_email text;
  u_meta jsonb;
  creator_name text;
  creator_handle text;
BEGIN
  SELECT email, raw_user_meta_data INTO u_email, u_meta FROM auth.users WHERE id = NEW.user_id;
  creator_name := COALESCE(
    NULLIF(trim(u_meta->>'display_name'), ''),
    NULLIF(trim(u_meta->>'username'), ''),
    split_part(COALESCE(u_email, 'admin'), '@', 1),
    'Admin'
  );
  creator_handle := trim(both '-' from regexp_replace(lower(creator_name), '[^a-z0-9]+', '-', 'g'));
  creator_handle := COALESCE(NULLIF(creator_handle, ''), 'admin') || '-' || left(replace(NEW.user_id::text, '-', ''), 5);

  INSERT INTO public.creator_profiles
    (user_id, display_name, handle, username, is_approved, approval_status)
  VALUES
    (NEW.user_id, creator_name, creator_handle, NULLIF(trim(u_meta->>'username'), ''), true, 'approved')
  ON CONFLICT (user_id) DO UPDATE
    SET is_approved = true,
        approval_status = 'approved';
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_app_admin_added_creator_profile ON public.app_admins;
CREATE TRIGGER on_app_admin_added_creator_profile
AFTER INSERT ON public.app_admins
FOR EACH ROW
EXECUTE FUNCTION public.handle_new_admin_creator_profile();

-- 4. Columns for custom text, Dark Mode theme preset, and Sticker interaction audio
ALTER TABLE public.site_settings
  ADD COLUMN IF NOT EXISTS eyebrow_text text,
  ADD COLUMN IF NOT EXISTS magic_tagline text,
  ADD COLUMN IF NOT EXISTS empty_search_text text,
  ADD COLUMN IF NOT EXISTS admin_bar_text text,
  ADD COLUMN IF NOT EXISTS sticker_sound_preset text DEFAULT 'chime',
  ADD COLUMN IF NOT EXISTS sticker_sound_url text,
  ADD COLUMN IF NOT EXISTS dark_custom_enabled boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS dark_cover_url text,
  ADD COLUMN IF NOT EXISTS dark_hero_text_color text,
  ADD COLUMN IF NOT EXISTS dark_hero_subtitle_color text,
  ADD COLUMN IF NOT EXISTS dark_hero_gradient_start text,
  ADD COLUMN IF NOT EXISTS dark_hero_gradient_end text,
  ADD COLUMN IF NOT EXISTS dark_accent_color text,
  ADD COLUMN IF NOT EXISTS dark_footer_color text,
  ADD COLUMN IF NOT EXISTS dark_body_font text,
  ADD COLUMN IF NOT EXISTS dark_header_font text,
  ADD COLUMN IF NOT EXISTS dark_bg_image text,
  ADD COLUMN IF NOT EXISTS dark_gradient_start text,
  ADD COLUMN IF NOT EXISTS dark_gradient_end text;

ALTER TABLE public.stickers
  ADD COLUMN IF NOT EXISTS sound_url text;

-- 5. Public Creator/Admin Announcements Bar + Public Activity Logs (visible to all guests without login)
CREATE TABLE IF NOT EXISTS public.creator_announcements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  author_name text NOT NULL,
  author_role text NOT NULL DEFAULT 'creator',
  content text NOT NULL,
  is_pinned boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.creator_announcements ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.creator_announcements TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.creator_announcements TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='creator_announcements' AND policyname='creator_announcements_public_read') THEN
    CREATE POLICY creator_announcements_public_read
    ON public.creator_announcements FOR SELECT TO anon, authenticated USING (true);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='creator_announcements' AND policyname='creator_announcements_creator_or_admin_insert') THEN
    CREATE POLICY creator_announcements_creator_or_admin_insert
    ON public.creator_announcements FOR INSERT TO authenticated
    WITH CHECK (
      EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = auth.uid())
      OR (
        auth.uid() = author_id
        AND EXISTS (SELECT 1 FROM public.creator_profiles WHERE user_id = auth.uid() AND is_approved = true)
      )
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='creator_announcements' AND policyname='creator_announcements_owner_or_admin_update') THEN
    CREATE POLICY creator_announcements_owner_or_admin_update
    ON public.creator_announcements FOR UPDATE TO authenticated
    USING (
      auth.uid() = author_id
      OR EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = auth.uid())
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='creator_announcements' AND policyname='creator_announcements_owner_or_admin_delete') THEN
    CREATE POLICY creator_announcements_owner_or_admin_delete
    ON public.creator_announcements FOR DELETE TO authenticated
    USING (
      auth.uid() = author_id
      OR EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = auth.uid())
    );
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.public_activity_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  creator_name text NOT NULL,
  item_name text NOT NULL,
  detail text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.public_activity_logs ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.public_activity_logs TO anon, authenticated;
GRANT INSERT, DELETE ON public.public_activity_logs TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='public_activity_logs' AND policyname='public_activity_logs_public_read') THEN
    CREATE POLICY public_activity_logs_public_read
    ON public.public_activity_logs FOR SELECT TO anon, authenticated USING (true);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='public_activity_logs' AND policyname='public_activity_logs_auth_insert') THEN
    CREATE POLICY public_activity_logs_auth_insert
    ON public.public_activity_logs FOR INSERT TO authenticated
    WITH CHECK (
      EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = auth.uid())
      OR EXISTS (SELECT 1 FROM public.creator_profiles WHERE user_id = auth.uid() AND is_approved = true)
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='public_activity_logs' AND policyname='public_activity_logs_admin_delete') THEN
    CREATE POLICY public_activity_logs_admin_delete
    ON public.public_activity_logs FOR DELETE TO authenticated
    USING (EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = auth.uid()));
  END IF;
END
$$;

-- 6. V10 Full Dark Mode Customization Parity & Per-Theme Stickers
ALTER TABLE public.site_settings
  ADD COLUMN IF NOT EXISTS dark_hero_gradient_mode text DEFAULT 'linear',
  ADD COLUMN IF NOT EXISTS dark_hero_gradient_third text,
  ADD COLUMN IF NOT EXISTS dark_hero_gradient_angle integer DEFAULT 120,
  ADD COLUMN IF NOT EXISTS dark_hero_fade_mode text DEFAULT 'fade',
  ADD COLUMN IF NOT EXISTS dark_hero_fade_height integer DEFAULT 58,
  ADD COLUMN IF NOT EXISTS dark_hero_fade_strength integer DEFAULT 72,
  ADD COLUMN IF NOT EXISTS dark_hero_text_shadow_enabled boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS dark_hero_text_shadow_color text,
  ADD COLUMN IF NOT EXISTS dark_hero_text_shadow_blur integer DEFAULT 4,
  ADD COLUMN IF NOT EXISTS dark_hero_text_shadow_x integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS dark_hero_text_shadow_y integer DEFAULT 2,
  ADD COLUMN IF NOT EXISTS dark_hero_text_bg_enabled boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS dark_hero_text_bg_color text,
  ADD COLUMN IF NOT EXISTS dark_hero_text_bg_opacity integer DEFAULT 55,
  ADD COLUMN IF NOT EXISTS dark_hero_text_bg_radius integer DEFAULT 14,
  ADD COLUMN IF NOT EXISTS dark_hero_text_bg_padding_x integer DEFAULT 18,
  ADD COLUMN IF NOT EXISTS dark_hero_text_bg_padding_y integer DEFAULT 10,
  ADD COLUMN IF NOT EXISTS dark_hero_frame_style text DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS dark_hero_frame_color text,
  ADD COLUMN IF NOT EXISTS dark_hero_frame_opacity integer DEFAULT 45,
  ADD COLUMN IF NOT EXISTS dark_hero_frame_width integer DEFAULT 2,
  ADD COLUMN IF NOT EXISTS dark_hero_frame_inset integer DEFAULT 12,
  ADD COLUMN IF NOT EXISTS dark_hero_text_frame_layout text DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS dark_hero_text_frame_color text,
  ADD COLUMN IF NOT EXISTS dark_hero_text_frame_opacity integer DEFAULT 28,
  ADD COLUMN IF NOT EXISTS dark_hero_text_frame_width integer DEFAULT 1,
  ADD COLUMN IF NOT EXISTS dark_hero_text_frame_radius integer DEFAULT 14,
  ADD COLUMN IF NOT EXISTS dark_hero_text_frame_padding integer DEFAULT 10,
  ADD COLUMN IF NOT EXISTS dark_gradient_mode text DEFAULT 'linear',
  ADD COLUMN IF NOT EXISTS dark_gradient_third text,
  ADD COLUMN IF NOT EXISTS dark_gradient_angle integer DEFAULT 135,
  ADD COLUMN IF NOT EXISTS dark_pattern text DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS dark_pattern_color text,
  ADD COLUMN IF NOT EXISTS dark_pattern_opacity integer DEFAULT 18,
  ADD COLUMN IF NOT EXISTS dark_background_mode text DEFAULT 'image_only',
  ADD COLUMN IF NOT EXISTS dark_overlay_opacity integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS dark_panel_opacity integer DEFAULT 88;

ALTER TABLE public.stickers
  ADD COLUMN IF NOT EXISTS theme_mode text DEFAULT 'light';

UPDATE public.stickers SET theme_mode = 'light' WHERE theme_mode IS NULL;

-- 7. V12 Header Frame Glow Intensity (Light & Dark Mode)
ALTER TABLE public.site_settings
  ADD COLUMN IF NOT EXISTS hero_frame_glow integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS dark_hero_frame_glow integer DEFAULT 0;

-- 8. V15 Dual/Separate Creator & Commission Sharer Roles + Admin Delete Policy on creator_profiles
ALTER TABLE public.creator_profiles
  ADD COLUMN IF NOT EXISTS can_creator boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_commission boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pending_creator boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pending_commission boolean NOT NULL DEFAULT false;

UPDATE public.creator_profiles
SET can_creator = true
WHERE is_approved = true AND can_creator = false;

UPDATE public.creator_profiles p
SET can_creator = true,
    can_commission = true,
    is_approved = true,
    approval_status = 'approved'
FROM public.app_admins a
WHERE p.user_id = a.user_id;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'creator_profiles'
      AND policyname = 'creator_profiles_admin_delete_any'
  ) THEN
    CREATE POLICY creator_profiles_admin_delete_any
    ON public.creator_profiles
    FOR DELETE
    TO authenticated
    USING (EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = auth.uid()));
  END IF;
END
$$;

-- 9. V16 Custom Sticker Tap Interaction Motion & Burst Effects
ALTER TABLE public.site_settings
  ADD COLUMN IF NOT EXISTS sticker_tap_motion text DEFAULT 'pop',
  ADD COLUMN IF NOT EXISTS sticker_tap_burst text DEFAULT 'sparkles';

ALTER TABLE public.stickers
  ADD COLUMN IF NOT EXISTS tap_motion text DEFAULT 'default',
  ADD COLUMN IF NOT EXISTS tap_burst text DEFAULT 'default';

-- 10. V17 Stop auto-creating public creator_profiles for pure Admin accounts
DROP TRIGGER IF EXISTS on_app_admin_added_creator_profile ON public.app_admins;

-- Clean up auto-generated Admin profiles that haven't posted any items
DELETE FROM public.creator_profiles p
WHERE p.user_id IN (SELECT user_id FROM public.app_admins)
  AND NOT EXISTS (SELECT 1 FROM public.library_items i WHERE i.owner_id = p.user_id);

-- 11. V19 Sticker Image Background Mode + Storage Upload Policies for Stickers
ALTER TABLE public.stickers
  ADD COLUMN IF NOT EXISTS bg_mode text DEFAULT 'normal';

INSERT INTO storage.buckets (id, name, public)
VALUES ('library-images', 'library-images', true)
ON CONFLICT (id) DO UPDATE SET public = true;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'library_images_public_read'
  ) THEN
    CREATE POLICY library_images_public_read
    ON storage.objects FOR SELECT
    TO public
    USING (bucket_id = 'library-images');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'library_images_auth_insert'
  ) THEN
    CREATE POLICY library_images_auth_insert
    ON storage.objects FOR INSERT
    TO authenticated
    WITH CHECK (bucket_id = 'library-images');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'library_images_auth_update'
  ) THEN
    CREATE POLICY library_images_auth_update
    ON storage.objects FOR UPDATE
    TO authenticated
    USING (bucket_id = 'library-images');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'library_images_auth_delete'
  ) THEN
    CREATE POLICY library_images_auth_delete
    ON storage.objects FOR DELETE
    TO authenticated
    USING (bucket_id = 'library-images');
  END IF;
END
$$;

-- 12. V20 Ambient Background Motion Settings (Light & Dark Mode)
ALTER TABLE public.site_settings
  ADD COLUMN IF NOT EXISTS bg_ambient text DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS bg_ambient_color text DEFAULT '#ffffff',
  ADD COLUMN IF NOT EXISTS bg_ambient_density integer DEFAULT 55,
  ADD COLUMN IF NOT EXISTS bg_ambient_speed numeric DEFAULT 1,
  ADD COLUMN IF NOT EXISTS dark_bg_ambient text DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS dark_bg_ambient_color text DEFAULT '#e9d5ff',
  ADD COLUMN IF NOT EXISTS dark_bg_ambient_density integer DEFAULT 60,
  ADD COLUMN IF NOT EXISTS dark_bg_ambient_speed numeric DEFAULT 1;

-- 13. V22 Lighting FX & Gradient Color Flow Settings (Light & Dark Mode)
ALTER TABLE public.site_settings
  ADD COLUMN IF NOT EXISTS bg_light_fx text DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS bg_light_intensity integer DEFAULT 45,
  ADD COLUMN IF NOT EXISTS bg_grad_flow text DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS dark_bg_light_fx text DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS dark_bg_light_intensity integer DEFAULT 50,
  ADD COLUMN IF NOT EXISTS dark_bg_grad_flow text DEFAULT 'none';

-- 14. V23 Allow Admins to insert personal approval notifications into site_notifications
ALTER TABLE IF EXISTS public.site_notifications ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON public.site_notifications TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'site_notifications'
      AND policyname = 'site_notifications_user_select'
  ) THEN
    CREATE POLICY site_notifications_user_select
    ON public.site_notifications FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'site_notifications'
      AND policyname = 'site_notifications_user_update'
  ) THEN
    CREATE POLICY site_notifications_user_update
    ON public.site_notifications FOR UPDATE
    TO authenticated
    USING (auth.uid() = user_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'site_notifications'
      AND policyname = 'site_notifications_admin_insert'
  ) THEN
    CREATE POLICY site_notifications_admin_insert
    ON public.site_notifications FOR INSERT
    TO authenticated
    WITH CHECK (EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = auth.uid()));
  END IF;
END
$$;

-- 15. V26 Ensure creator_profiles has theme jsonb column and proper user update policy
ALTER TABLE public.creator_profiles
  ADD COLUMN IF NOT EXISTS theme jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS bio text,
  ADD COLUMN IF NOT EXISTS links jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS avatar_url text,
  ADD COLUMN IF NOT EXISTS banner_url text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'creator_profiles'
      AND policyname = 'creator_profiles_owner_update'
  ) THEN
    CREATE POLICY creator_profiles_owner_update
    ON public.creator_profiles
    FOR UPDATE
    TO authenticated
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);
  END IF;
END
$$;

-- 16. V26.1 Ensure site_notifications table & admin insert policy exist
CREATE TABLE IF NOT EXISTS public.site_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  body text,
  is_read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.site_notifications ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON public.site_notifications TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'site_notifications'
      AND policyname = 'site_notifications_user_select'
  ) THEN
    CREATE POLICY site_notifications_user_select
    ON public.site_notifications FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'site_notifications'
      AND policyname = 'site_notifications_user_update'
  ) THEN
    CREATE POLICY site_notifications_user_update
    ON public.site_notifications FOR UPDATE
    TO authenticated
    USING (auth.uid() = user_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'site_notifications'
      AND policyname = 'site_notifications_admin_insert'
  ) THEN
    CREATE POLICY site_notifications_admin_insert
    ON public.site_notifications FOR INSERT
    TO authenticated
    WITH CHECK (EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = auth.uid()));
  END IF;
END
$$;

-- 17. V27 Allow rating to be NULL on creator_feedback & allow Admin to delete any creator_feedback
ALTER TABLE IF EXISTS public.creator_feedback
  ALTER COLUMN rating DROP NOT NULL;

GRANT SELECT, INSERT, DELETE ON public.creator_feedback TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'creator_feedback'
      AND policyname = 'creator_feedback_admin_delete'
  ) THEN
    CREATE POLICY creator_feedback_admin_delete
    ON public.creator_feedback FOR DELETE
    TO authenticated
    USING (EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = auth.uid()));
  END IF;
END
$$;

-- 18. V29 Allow reading admin user_ids for directory badge display
ALTER TABLE IF EXISTS public.app_admins ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.app_admins TO anon, authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'app_admins'
      AND policyname = 'app_admins_public_read_ids'
  ) THEN
    CREATE POLICY app_admins_public_read_ids
    ON public.app_admins FOR SELECT
    TO anon, authenticated
    USING (true);
  END IF;
END
$$;


-- 19. V39 Allow public/authenticated read on creator_profiles so Admin & approved roles are visible across accounts
ALTER TABLE IF EXISTS public.creator_profiles ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.creator_profiles TO anon, authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'creator_profiles'
      AND policyname = 'creator_profiles_public_read'
  ) THEN
    CREATE POLICY creator_profiles_public_read
    ON public.creator_profiles FOR SELECT
    TO anon, authenticated
    USING (true);
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';
