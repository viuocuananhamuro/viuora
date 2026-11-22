-- v57: cho phép người đăng tải đăng / sửa LINK (library_items) vào nhóm của chính mình
-- Chạy trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn). Cần đã chạy v56 trước.
--
-- (Tùy chọn) Muốn xem các policy hiện có của bảng library_items để đối chiếu, chạy riêng:
--   select policyname, cmd, qual, with_check from pg_policies where tablename = 'library_items';

DROP POLICY IF EXISTS library_items_owner_insert ON public.library_items;
CREATE POLICY library_items_owner_insert ON public.library_items
FOR INSERT TO authenticated
WITH CHECK (
  owner_id = auth.uid()
  AND EXISTS (
    SELECT 1
    FROM public.creator_profiles p
    JOIN public.categories c ON c.id = library_items.category_id
    WHERE p.user_id = auth.uid()
      AND ((library_items.main = 'creator' AND p.can_creator) OR (library_items.main = 'commission' AND p.can_commission))
      AND c.section = library_items.main
      AND (c.owner_id = auth.uid() OR lower(trim(c.owner_name)) = lower(trim(p.display_name)))
  )
);

DROP POLICY IF EXISTS library_items_owner_update ON public.library_items;
CREATE POLICY library_items_owner_update ON public.library_items
FOR UPDATE TO authenticated
USING (owner_id = auth.uid())
WITH CHECK (
  owner_id = auth.uid()
  AND EXISTS (
    SELECT 1
    FROM public.creator_profiles p
    JOIN public.categories c ON c.id = library_items.category_id
    WHERE p.user_id = auth.uid()
      AND ((library_items.main = 'creator' AND p.can_creator) OR (library_items.main = 'commission' AND p.can_commission))
      AND c.section = library_items.main
      AND (c.owner_id = auth.uid() OR lower(trim(c.owner_name)) = lower(trim(p.display_name)))
  )
);

NOTIFY pgrst, 'reload schema';
