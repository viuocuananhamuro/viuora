-- Anime GGAI Library V54 — Fix: (1) Admin lập page không thêm được Admin, (2) đăng ký Bbi share comm bị duyệt thành Creator
-- CHẠY FILE NÀY 1 LẦN trong Supabase SQL Editor. An toàn khi chạy lại, không xóa dữ liệu.
-- ⚠️ ĐỪNG chạy lại cả file supabase_upgrade_v35.sql nữa: ở đầu file đó có lệnh đổi mọi hồ sơ
--    (is_approved=false & approval_status='approved') về 'pending' — chính lệnh này làm Bbi share comm
--    đã duyệt bị rớt về "chờ duyệt" rồi bị duyệt lại thành Creator.

-- ============ 1. QUYỀN ADMIN ============
ALTER TABLE public.app_admins
  ADD COLUMN IF NOT EXISTS admin_role text NOT NULL DEFAULT 'admin',
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

GRANT SELECT, INSERT, UPDATE, DELETE ON public.app_admins TO authenticated;
GRANT SELECT ON public.app_admins TO anon;

-- Đảm bảo các cột vai trò tồn tại (phòng khi các bản nâng cấp cũ chưa chạy)
ALTER TABLE public.creator_profiles
  ADD COLUMN IF NOT EXISTS can_creator boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_commission boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pending_creator boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pending_commission boolean NOT NULL DEFAULT false;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'app_admins_admin_role_check') THEN
    ALTER TABLE public.app_admins
      ADD CONSTRAINT app_admins_admin_role_check CHECK (admin_role IN ('founder', 'admin'));
  END IF;
END
$$;

-- Cột admin_role mới tạo mặc định là 'admin' cho tất cả => phải chọn lại Admin lập page (founder).
-- Nếu chưa có founder nào, tự chọn tài khoản Admin tạo sớm nhất.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.app_admins WHERE admin_role = 'founder') THEN
    UPDATE public.app_admins
    SET admin_role = 'founder'
    WHERE user_id = (
      SELECT a.user_id
      FROM public.app_admins a
      LEFT JOIN auth.users u ON u.id = a.user_id
      ORDER BY u.created_at ASC NULLS LAST
      LIMIT 1
    );
  END IF;
END
$$;

-- Nếu người được chọn ở trên KHÔNG phải bạn, chạy lệnh dưới (đổi email, bỏ dấu -- ở đầu 3 dòng):
-- UPDATE public.app_admins SET admin_role = 'admin';
-- UPDATE public.app_admins SET admin_role = 'founder'
--   WHERE user_id = (SELECT id FROM auth.users WHERE email = 'EMAIL_CỦA_BẠN@gmail.com');

-- Hàm cấp Admin: chỉ 'founder' (Admin lập page) gọi được, chạy với quyền SECURITY DEFINER nên không dính lỗi permission denied
CREATE OR REPLACE FUNCTION public.grant_admin_role(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.app_admins WHERE user_id = auth.uid() AND admin_role = 'founder'
  ) THEN
    RAISE EXCEPTION 'Chỉ Admin lập page mới có quyền thêm Admin';
  END IF;

  INSERT INTO public.app_admins (user_id, admin_role)
  SELECT p_user_id, 'admin'
  WHERE NOT EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = p_user_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_admin_role(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.app_admins WHERE user_id = auth.uid() AND admin_role = 'founder'
  ) THEN
    RAISE EXCEPTION 'Chỉ Admin lập page mới có quyền gỡ Admin';
  END IF;

  DELETE FROM public.app_admins WHERE user_id = p_user_id AND admin_role <> 'founder';
END;
$$;

GRANT EXECUTE ON FUNCTION public.grant_admin_role(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_admin_role(uuid) TO authenticated;

-- Admin được sửa hồ sơ của người khác (cần để duyệt / từ chối)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.creator_profiles TO authenticated;
DROP POLICY IF EXISTS creator_profiles_admin_update_any ON public.creator_profiles;
CREATE POLICY creator_profiles_admin_update_any
ON public.creator_profiles FOR UPDATE TO authenticated
USING (EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = auth.uid()));

-- ============ 2. LƯU VAI TRÒ NGƯỜI DÙNG ĐĂNG KÝ ============
ALTER TABLE public.creator_profiles ADD COLUMN IF NOT EXISTS requested_role text;

-- Điền vai trò đã đăng ký cho hồ sơ cũ
UPDATE public.creator_profiles p
SET requested_role = CASE
  WHEN p.pending_commission THEN 'commission'
  WHEN p.pending_creator THEN 'creator'
  WHEN COALESCE(u.raw_user_meta_data->>'selected_role','') = 'commission'
    OR LOWER(COALESCE(u.raw_user_meta_data->>'want_commission','false')) = 'true' THEN 'commission'
  WHEN p.can_commission AND NOT p.can_creator THEN 'commission'
  ELSE 'creator'
END
FROM auth.users u
WHERE u.id = p.user_id AND p.requested_role IS NULL;

-- Sửa các hồ sơ đã được duyệt nhưng bị rớt về 'pending' (do chạy lại v35)
UPDATE public.creator_profiles p
SET approval_status = 'approved'
WHERE (p.can_creator OR p.can_commission)
  AND p.approval_status <> 'approved'
  AND NOT p.pending_creator AND NOT p.pending_commission;

-- Hồ sơ đang chờ duyệt mà mất cờ vai trò -> khôi phục đúng vai trò đã đăng ký
UPDATE public.creator_profiles p
SET pending_commission = (p.requested_role = 'commission'),
    pending_creator    = (COALESCE(p.requested_role,'creator') <> 'commission')
WHERE p.approval_status = 'pending'
  AND NOT p.pending_creator AND NOT p.pending_commission
  AND NOT p.can_creator AND NOT p.can_commission
  AND NOT EXISTS (SELECT 1 FROM public.app_admins a WHERE a.user_id = p.user_id);

-- Trigger đăng ký: ghi đúng vai trò (creator hoặc commission)
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
  want_comm boolean;
  want_crt boolean;
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

    want_comm := LOWER(COALESCE(NEW.raw_user_meta_data->>'want_commission', 'false')) = 'true'
                 OR COALESCE(NEW.raw_user_meta_data->>'selected_role', '') = 'commission';
    want_crt := NOT want_comm;

    INSERT INTO public.creator_profiles (
      user_id, display_name, handle, username,
      is_approved, can_creator, can_commission,
      pending_creator, pending_commission, requested_role, approval_status
    )
    VALUES (
      NEW.id, creator_name, creator_handle,
      NULLIF(trim(NEW.raw_user_meta_data->>'username'), ''),
      is_admin_user, false, false,
      CASE WHEN is_admin_user THEN false ELSE want_crt END,
      CASE WHEN is_admin_user THEN false ELSE want_comm END,
      CASE WHEN want_comm THEN 'commission' ELSE 'creator' END,
      CASE WHEN is_admin_user THEN 'approved' ELSE 'pending' END
    )
    ON CONFLICT (user_id) DO UPDATE
      SET display_name = EXCLUDED.display_name,
          is_approved = CASE WHEN is_admin_user THEN true ELSE creator_profiles.is_approved END,
          pending_creator = CASE WHEN is_admin_user THEN false ELSE EXCLUDED.pending_creator END,
          pending_commission = CASE WHEN is_admin_user THEN false ELSE EXCLUDED.pending_commission END,
          requested_role = EXCLUDED.requested_role,
          approval_status = CASE WHEN is_admin_user THEN 'approved' ELSE creator_profiles.approval_status END;
  END IF;
  RETURN NEW;
END;
$$;

-- RPC gửi yêu cầu vai trò: ghi đúng vai trò đã chọn
CREATE OR REPLACE FUNCTION public.submit_role_request(
  p_display_name text,
  p_handle text,
  p_username text,
  p_want_creator boolean,
  p_want_commission boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid uuid := auth.uid();
  clean_comm boolean := COALESCE(p_want_commission, false);
  clean_crt boolean := CASE WHEN COALESCE(p_want_commission, false) THEN false ELSE COALESCE(p_want_creator, true) END;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  INSERT INTO public.creator_profiles (
    user_id, display_name, handle, username,
    is_approved, can_creator, can_commission,
    pending_creator, pending_commission, requested_role, approval_status
  )
  VALUES (
    uid,
    COALESCE(NULLIF(trim(p_display_name), ''), 'Member'),
    COALESCE(NULLIF(trim(p_handle), ''), 'member-' || left(replace(uid::text, '-', ''), 5)),
    NULLIF(trim(p_username), ''),
    false, false, false,
    clean_crt, clean_comm,
    CASE WHEN clean_comm THEN 'commission' ELSE 'creator' END,
    'pending'
  )
  ON CONFLICT (user_id) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        is_approved = false,
        can_creator = false,
        can_commission = false,
        pending_creator = clean_crt,
        pending_commission = clean_comm,
        requested_role = EXCLUDED.requested_role,
        approval_status = 'pending';
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_role_request(text, text, text, boolean, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
